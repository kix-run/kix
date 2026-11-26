//! `kix plan`: the deploy pipeline as a server-side dry run.
//!
//! The plan is made by the code that deploys. [`prepare`] builds and runs
//! [`kix::plan::Planner`], which computes the deploy's actions; [`dry_run`]
//! runs the engine over them with every write sent as `dryRun=All`, so the
//! apiserver answers for each object; [`document`] turns those answers into
//! the [`Plan`] document `kix diff` and `kix plan --read-only` also emit.
//! `kix deploy` runs the same three steps before it asks for confirmation.

use std::collections::{HashMap, HashSet};
use std::io::IsTerminal;
use std::path::Path;
use std::sync::{Arc, Mutex};

use miette::{Result, miette};
use serde_json::Value;

use kix::build_source::InstallableBuild;
use kix::build_source::SopsSources;
use kix::cluster::classify::{ChangedCrds, DeployScope, Verdict as DryRunVerdict, classify};
use kix::cluster::preview::{DryRunAnswer, DryRunOutcome, PruneAnswer, Refusal};
use kix::cluster::readiness::{self, ControllerState};
use kix::cluster::scheduler::{self, OnErrorPolicy, PrunePolicy, SchedulerConfig};
use kix::cluster::stream::{
    CancelReason, DeployEvent, DeployObserver, NodeId, TransitionKind, Verdict,
};
use kix::cluster::watchdog::StallPolicy;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::lifecycle;
use kix::manifest::types::ResourceId;
use kix::plan::document::{
    AdmissionRefusal, Build, Checked, Conflict, ConflictOwner, DeployedBuild, Detail, LeftBehind,
    MadeBy, NotCheckedReason, ObjectWrite, Plan, PlanFlags, PruneController, PruneControllerState,
    PruneEntry, PruneFate, RefusalReason, UncheckedObject, UncheckedReason,
};
use kix::plan::server::comparable;
use kix::plan::{CheckedPlan, ManifestIndex, OldSide, PlanEvent, Planned, Planner, Target};

use crate::cli::{OutputFormat, PlanArgs, PlanCommandArgs};
use crate::output;
use crate::plan::{self, render};

use super::CommandContext;
use crate::exit::Exit;

pub fn run(args: &PlanArgs, save: Option<&Path>, ctx: &mut CommandContext) -> Result<Exit> {
    // `Command::formats` allows only text and Markdown.
    let format = output::format();
    let Some(mut p) = prepare(args, flags_of(args), ctx)? else {
        // A plan file needs a plan, and a caller that asked for one must
        // not find exit 0 and no file.
        if let Some(path) = save {
            return Err(miette!(
                "the build has no resources, so there is no plan to save; {} was not written",
                path.display()
            ));
        }
        return Ok(Exit::Success);
    };
    super::deploy::stops::warn(&args.cluster, p.baseline.active());
    // A plan decrypts no SOPS file the build carries: those Secrets get
    // placeholder values, so planning before anyone has approved reads no
    // secret.
    let report = match p.client().cloned() {
        Some(client) => Some(dry_run(&mut p, true, client, ctx)?),
        None => None,
    };
    let doc = document(&mut p, report.as_ref(), save.is_some());
    if let Some(path) = save {
        let sha256 = plan::save(doc.clone(), p.build.graph(), path)?;
        crate::esay!("Saved the plan to {} (sha256:{sha256})", path.display());
    }

    match format {
        OutputFormat::Markdown => print!("{}", markdown(&p, &doc)),
        _ => {
            if !output::quiet() {
                print_migrations(&doc, p.checked.flags().accept_migrations);
                // A plan exists to be read, so it always shows each change.
                print_text(&p, &doc, true);
            }
        }
    }

    let migrations_refused =
        !doc.migrations.items().is_empty() && !p.checked.flags().accept_migrations;
    if doc.stops() || migrations_refused {
        return Ok(Exit::PlanWouldStop);
    }
    if doc.has_changes() {
        return Ok(Exit::PlanHasChanges);
    }
    Ok(Exit::Success)
}

/// Run `kix plan --read-only`, which compares the build with the live
/// cluster using only `get` and `list`.
pub fn run_read_only(args: &PlanCommandArgs, ctx: &mut CommandContext) -> Result<Exit> {
    super::diff::compare(
        &super::diff::Comparison {
            command: "kix plan --read-only",
            cluster: &args.plan.cluster,
            bundle: args.plan.bundle.as_deref(),
            baseline: super::diff::Baseline::Live,
            detail: args.detail,
            out: args.out.as_deref(),
        },
        ctx,
    )
}

/// Extract [`PlanFlags`] from CLI arguments.
pub(crate) fn flags_of(args: &PlanArgs) -> PlanFlags {
    PlanFlags {
        prune: PlanFlags::prune_policy_of(args.prune, args.skip_orphan_check),
        reconcile: args.reconcile,
        force_conflicts: args.force_conflicts,
        accept_migrations: args.accept_migrations,
    }
}

/// Select the baseline source (`OldSide`) for planning: the local cache under
/// `--offline`, or the live cluster otherwise.
fn old_side(args: &PlanArgs, ctx: &CommandContext) -> OldSide {
    if args.offline {
        OldSide::LocalCache
    } else {
        OldSide::Cluster {
            context: ctx.global.context.clone(),
            policy: crate::client::policy(),
        }
    }
}

/// Build the target cluster and run [`Planner`] with `flags`.
///
/// Returns `Ok(None)` when the build contains no resources. Progress messages
/// are written via [`crate::say!`] so `-o markdown` and `-o json` keep stdout
/// clean.
pub(crate) fn prepare(
    args: &PlanArgs,
    flags: PlanFlags,
    ctx: &CommandContext,
) -> Result<Option<Planned>> {
    let build = new_build(args, ctx)?;
    output::clear_status_line();
    let graph = build.graph();
    crate::say!(
        "Cluster {}: {} manifests",
        output::bold(&graph.cluster_name),
        graph.resources.len(),
    );
    if graph.resources.is_empty() {
        crate::say!("Nothing to deploy.");
        return Ok(None);
    }
    let report = |event: PlanEvent<'_>| plan::progress::print(event);
    let planned = ctx
        .runtime()?
        .block_on(Planner::new(flags, &report).run(build, &old_side(args, ctx)))
        .map_err(|e| miette!("{e}"))?;
    Ok(Some(planned))
}

/// Load the target build from `--bundle` or by building the flake into the
/// local Nix store.
///
/// Rejects builds pinned to a pre-migration Kix library revision that still
/// renders Kix's CRDs under the retired API group.
fn new_build(args: &PlanArgs, ctx: &CommandContext) -> Result<InstallableBuild> {
    let build = match &args.bundle {
        Some(path) => {
            crate::say!("Reading bundle {}...", path.display());
            super::read_bundle(path, &args.deployed_bundles, &args.cluster)?
        }
        None => {
            let status = |msg: &str| output::status_line(msg);
            crate::say!("Building cluster '{}'...", output::bold(&args.cluster));
            super::build_flake(&ctx.global, &args.cluster, &status, super::BUILD_FAILED)?
        }
    };
    build.installable().map_err(|e| miette!("{e}"))
}

/// Index the old and new graphs' manifests, overlaying live objects and
/// dry-run results returned by the apiserver.
///
/// Refused writes keep the build's manifest so diffs show what the deploy
/// attempted to send.
fn manifest_index<'a>(
    old: &'a StoreGraph,
    new: &'a StoreGraph,
    answers: &[DryRunAnswer],
) -> ManifestIndex<'a> {
    let mut index = ManifestIndex::new(old, new);
    for answer in answers {
        let (live, result) = match &answer.outcome {
            DryRunOutcome::Applied(p) => (p.live.as_ref(), Some(&p.result)),
            DryRunOutcome::Recreated {
                live,
                result: Some(result),
                ..
            } => (live.as_ref(), Some(result)),
            _ => continue,
        };
        index.answered(&answer.rid, live.map(comparable), result.map(comparable));
    }
    index
}

/// Results collected from a server-side dry run of the deploy plan.
pub(crate) struct DryRunReport {
    pub answers: Vec<DryRunAnswer>,
    /// Nodes the engine failed with no apiserver answer recorded.
    pub failed: HashMap<ResourceId, String>,
    /// Nodes the engine never tried, with the failed predecessor.
    pub cancelled: HashMap<ResourceId, Option<ResourceId>>,
    /// The APIs the apiserver serves, as discovery lists them.
    pub served: Vec<(kube::discovery::ApiResource, kube::discovery::Scope)>,
    /// For each orphan that declares a kind no object of the new build
    /// declares, the objects of that kind the prune leaves on the cluster.
    pub left_behind: HashMap<ResourceId, LeftBehind>,
}

/// Return, for each orphan that declares a kind no object of the new build
/// declares, the objects of that kind that the prune leaves on the cluster.
/// Only a prune that deletes removes the controller that handles them, so a
/// plan with another prune policy lists none.
async fn left_behind_of(
    checked: &CheckedPlan,
    client: &kube::Client,
) -> HashMap<ResourceId, LeftBehind> {
    if checked.flags().prune != PrunePolicy::Delete {
        return HashMap::new();
    }
    let deleting: HashSet<ResourceId> = checked.orphans().iter().cloned().collect();
    left_behind(client, &checked.kinds_leaving(), &deleting).await
}

/// Return, for each `(declarer, crd)` of `leaving`, the objects of the kind
/// `crd` defines that stay on the cluster when a prune deletes `deleting`
/// ([`kix::cluster::left_behind::left_behind`]). A kind Kix cannot list is
/// left out, with a warning.
pub(crate) async fn left_behind(
    client: &kube::Client,
    leaving: &[(ResourceId, String)],
    deleting: &HashSet<ResourceId>,
) -> HashMap<ResourceId, LeftBehind> {
    let mut listed = Vec::new();
    for (_, crd) in leaving {
        match kix::cluster::left_behind::list(client, crd).await {
            Ok(Some(kind)) => listed.push(kind),
            Ok(None) => {}
            Err(e) => eprintln!(
                "warning: could not check CustomResourceDefinition {crd} for custom resources left on the cluster: {e}\n  Kix skipped this check and continued, so the plan will not warn if custom resources for {crd} remain after `--prune`.\n  Grant this account `get` permission on CustomResourceDefinition {crd} and cluster-wide `list` permission on its custom resources (or fix the error above), then run the command again."
            ),
        }
    }
    let mut by_crd = kix::cluster::left_behind::left_behind(&listed, deleting);
    leaving
        .iter()
        .filter_map(|(declarer, crd)| Some((declarer.clone(), by_crd.remove(crd)?)))
        .collect()
}

/// Run the deploy's engine plan with every write sent as a dry run
/// ([`dry_run_of`]).
///
/// `placeholders` goes to [`kix::build_source::Build::sops_sources`]: true
/// for `kix plan`, which decrypts nothing.
pub(crate) fn dry_run(
    p: &mut Planned,
    placeholders: bool,
    client: kube::Client,
    ctx: &CommandContext,
) -> Result<DryRunReport> {
    let sops = p.sops_sources(placeholders).map_err(|e| miette!("{e}"))?;
    ctx.runtime()?
        .block_on(dry_run_of(&p.checked, client, sops, true))
}

/// Run the engine over `checked` with every write sent as a dry run, for
/// `kix plan`, `kix deploy`, and `kix rollback`.
///
/// The engine runs with `--on-error continue`, and under dry run it still
/// tries the dependents of a refused node, so one refused write does not hide
/// the answers for the rest. Nothing is persisted: every write goes with
/// `dryRun=All` and the Activation record's lifecycle writes are skipped
/// ([`kix::plan::CheckedPlan::dry_run`]). `names_flags` says whether the
/// engine's messages may suggest `kix deploy`'s flags.
pub(crate) async fn dry_run_of(
    checked: &CheckedPlan,
    client: kube::Client,
    sops: SopsSources,
    names_flags: bool,
) -> Result<DryRunReport> {
    let left_behind = left_behind_of(checked, &client).await;
    let target = Target::connect(client, sops)
        .await
        .map_err(|e| miette!("{e}"))?;
    kix::legacy_domain::check_discovery(target.discovery()).map_err(|e| miette!("{e}"))?;
    let served = target.discovery().to_vec();

    let config = scheduler_config(
        readiness::DEFAULT_TIMEOUT,
        OnErrorPolicy::Continue,
        names_flags,
    );
    let cancel = config.cancel.clone();
    crate::interrupt::cancel_on_interrupt(&cancel);

    // Count the writes the plan's `objects` lists, so the progress line
    // and the plan's object count agree.
    let writes: HashSet<ResourceId> = checked
        .objects()
        .writes
        .iter()
        .filter(|w| w.change.certain())
        .map(ObjectWrite::resource_id)
        .collect();
    let observer = Arc::new(DryRunObserver::new(writes));
    let (result, answers) = checked.dry_run(target, config, observer.clone()).await;
    // Cancelling the token ends its interrupt watcher, so Ctrl-C at the
    // deploy's confirmation exits the process.
    let interrupted = cancel.is_cancelled();
    cancel.cancel();
    observer.finish();
    if interrupted {
        return Err(miette!(
            "dry run interrupted. Nothing was applied to the cluster."
        ));
    }
    if let Err(e) = &result
        && !matches!(e, scheduler::DeployError::NodesFailed { .. })
    {
        return Err(miette!(
            "the dry run could not finish: {e}. Nothing was applied to the cluster. Next: resolve the problem above and run the command again."
        ));
    }

    let answered: HashSet<&ResourceId> = answers.iter().map(|a| &a.rid).collect();
    let seen = observer.take();
    let failed = seen
        .failed
        .into_iter()
        .filter(|(rid, _)| !answered.contains(rid))
        .collect();
    Ok(DryRunReport {
        answers,
        failed,
        cancelled: seen.cancelled,
        served,
        left_behind,
    })
}

/// Return the engine settings `kix plan`, `kix deploy`, and `kix rollback`
/// run with. Each run has its own cancel token.
pub(crate) fn scheduler_config(
    timeout: std::time::Duration,
    on_error: OnErrorPolicy,
    names_flags: bool,
) -> SchedulerConfig {
    SchedulerConfig {
        timeout,
        on_error,
        cancel: kix::cluster::cancel::CancelToken::new(),
        concurrency: scheduler::CONCURRENCY,
        stall: StallPolicy::from_env(),
        check_unchanged: true,
        names_flags,
    }
}

#[derive(Default)]
struct Seen {
    failed: HashMap<ResourceId, String>,
    cancelled: HashMap<ResourceId, Option<ResourceId>>,
    done: HashSet<ResourceId>,
}

/// Collects the engine's verdicts in a dry run, and shows a progress line
/// on stderr.
struct DryRunObserver {
    seen: Mutex<Seen>,
    bar: Option<indicatif::ProgressBar>,
    /// The writes the progress line counts.
    writes: HashSet<ResourceId>,
}

impl DryRunObserver {
    fn new(counted: HashSet<ResourceId>) -> Self {
        let writes = counted.len();
        let quiet = output::quiet();
        let bar = (!quiet && std::io::stderr().is_terminal() && writes > 0).then(|| {
            let bar = indicatif::ProgressBar::new(writes as u64);
            bar.set_style(
                indicatif::ProgressStyle::default_spinner()
                    .template("{spinner:.cyan} Checking {len} writes with the apiserver (dry run): {pos}/{len}")
                    .expect("valid template"),
            );
            bar.enable_steady_tick(std::time::Duration::from_millis(80));
            bar
        });
        if bar.is_none() && !quiet && writes > 0 {
            eprintln!("Checking {writes} writes with the apiserver (dry run)...");
        }
        DryRunObserver {
            seen: Mutex::new(Seen::default()),
            bar,
            writes: counted,
        }
    }

    fn finish(&self) {
        if let Some(bar) = &self.bar {
            bar.finish_and_clear();
        }
    }

    fn take(&self) -> Seen {
        self.seen
            .lock()
            .map(|mut s| std::mem::take(&mut *s))
            .unwrap_or_default()
    }
}

impl DeployObserver for DryRunObserver {
    fn on_event(&self, event: &DeployEvent) {
        let DeployEvent::NodeStateChanged {
            node: NodeId::Resource(rid),
            kind,
            verdict,
            ..
        } = event
        else {
            return;
        };
        if matches!(kind, TransitionKind::Delete) || !verdict.is_terminal() {
            return;
        }
        let Ok(mut seen) = self.seen.lock() else {
            return;
        };
        if self.writes.contains(rid)
            && seen.done.insert(rid.clone())
            && let Some(bar) = &self.bar
        {
            bar.set_position(seen.done.len() as u64);
        }
        if matches!(kind, TransitionKind::Skip) {
            return;
        }
        match verdict {
            Verdict::Failed { message } => {
                seen.failed.insert(rid.clone(), message.clone());
            }
            Verdict::Cancelled { because } => {
                let by = match because {
                    CancelReason::PredecessorFailed(pred) => Some(pred.clone()),
                    CancelReason::External => None,
                };
                seen.cancelled.insert(rid.clone(), by);
            }
            _ => {}
        }
    }
}

/// Build the [`Plan`] document and overlay the apiserver's dry-run answers onto
/// the package diff ([`Planned::overlay`]).
///
/// When `manifests` is `true`, includes full manifest diffs (`Detail::Manifests`)
/// as required when saving a plan file; otherwise uses `Detail::Plain`.
pub(crate) fn document(p: &mut Planned, report: Option<&DryRunReport>, manifests: bool) -> Plan {
    let connected = p.client().is_some();
    let made_by = if connected {
        MadeBy::DryRun
    } else {
        MadeBy::Builds
    };
    let answers: &[DryRunAnswer] = report.map(|r| r.answers.as_slice()).unwrap_or(&[]);
    let drift = p.overlay(answers);

    // Built only for `--detail manifests`. Without the deployed build the
    // old side is rebuilt from the old manifests, as the package diff is.
    let rebuilt;
    let index = if manifests {
        let old = match p.baseline.active_graph() {
            Some(old) => old,
            None => {
                rebuilt = p.baseline.synthesized_side(p.build.graph());
                &rebuilt
            }
        };
        Some(manifest_index(old, p.build.graph(), answers))
    } else {
        None
    };
    let detail = match &index {
        Some(index) => Detail::Manifests(index),
        None => Detail::Plain,
    };

    let mut doc = Plan::new(
        plan::kix_build(),
        made_by,
        &p.build.graph().cluster_name,
        Build::of(p.build.graph()),
        p.checked.pkg_diff(),
        detail,
        &p.migration_pairs,
        NotCheckedReason::BuildsOnly,
    );
    doc.warnings = p.build.warnings().to_vec();
    doc.kubernetes = p.connected.as_ref().map(|c| (&c.connection).into());
    doc.deployed = p.baseline.active().map(|a| DeployedBuild {
        activation: a.name.clone(),
        identity_hash: a.identity_hash.clone(),
        store_path: a.built_via.clone(),
    });
    doc.flags = Some(p.checked.flags());
    doc.objects_digest = Some(kix::plan::objects::digest(p.checked.objects()));
    doc.objects = Some(p.checked.objects().clone());
    if !connected {
        return doc;
    }

    fill_checks(
        &mut doc,
        &p.checked,
        &p.build.graph().cluster_name,
        p.new_manifests(),
        report,
    );
    doc.drift = match drift {
        Some(drift) => Checked::found(drift),
        None => Checked::not_checked(NotCheckedReason::DeployedBuildUnavailable),
    };
    // A custom resource whose CRD this deploy changes was checked against the
    // CRD on the cluster now, which prunes the fields the new CRD adds.
    let changed_crds = ChangedCrds::of(answers);
    let manifests: HashMap<ResourceId, &Value> = p
        .new_manifests()
        .iter()
        .map(|m| (ResourceId::from_value(m), m))
        .collect();
    doc.not_kept = kix::plan::server::not_kept(answers, |rid| {
        manifests
            .get(rid)
            .is_some_and(|m| changed_crds.crd_of(m).is_some())
    });
    doc
}

/// Fill the sections of `doc` that the dry run in `report` answers: field
/// ownership conflicts, refused writes, objects it did not check, and the
/// prune. `build` is every manifest of the build `checked` deploys to Kix
/// cluster `cluster`. A deploy and a rollback stop on what this finds
/// ([`Plan::stops`]).
pub(crate) fn fill_checks(
    doc: &mut Plan,
    checked: &CheckedPlan,
    cluster: &str,
    build: &[Value],
    report: Option<&DryRunReport>,
) {
    let answers: &[DryRunAnswer] = report.map(|r| r.answers.as_slice()).unwrap_or(&[]);
    let mut conflicts = Vec::new();
    let mut admission = Vec::new();
    let mut not_checked = Vec::new();
    let prune_answers: HashMap<ResourceId, PruneAnswer> = answers
        .iter()
        .filter_map(|a| match &a.outcome {
            DryRunOutcome::Pruned(answer) => Some((a.rid.clone(), answer.clone())),
            _ => None,
        })
        .collect();
    let scope = DeployScope {
        cluster,
        build,
        plan: checked.plan(),
        served: report.map_or(&[], |r| &r.served),
    };

    for (rid, verdict) in classify(answers, &scope) {
        let resource = rid.display_id();
        let refusal = match verdict {
            DryRunVerdict::Accepted => continue,
            DryRunVerdict::NotChecked {
                reason,
                because,
                detail,
            } => {
                not_checked.push(UncheckedObject {
                    resource,
                    reason,
                    because: because.map(|b| b.display_id()),
                    detail,
                });
                continue;
            }
            DryRunVerdict::Refused(refusal) => refusal,
        };
        match refusal {
            Refusal::Conflict { owners, message } => conflicts.push(Conflict {
                resource,
                owners: owners
                    .into_iter()
                    .map(|o| ConflictOwner {
                        manager: o.manager,
                        fields: o.fields,
                    })
                    .collect(),
                message,
            }),
            refusal => {
                let (reason, webhook) = admission_reason(&refusal);
                admission.push(AdmissionRefusal {
                    resource,
                    reason,
                    webhook,
                    message: refusal.message(),
                });
            }
        }
    }
    if let Some(report) = report {
        for (rid, message) in &report.failed {
            admission.push(AdmissionRefusal {
                resource: rid.display_id(),
                reason: RefusalReason::Other,
                webhook: None,
                message: message.clone(),
            });
        }
        for (rid, by) in &report.cancelled {
            not_checked.push(UncheckedObject {
                resource: rid.display_id(),
                reason: UncheckedReason::DependencyNotChecked,
                because: None,
                detail: match by {
                    Some(pred) => format!("depends on {pred}"),
                    None => "the dry run was cancelled".into(),
                },
            });
        }
    }
    conflicts.sort_by(|a, b| a.resource.cmp(&b.resource));
    admission.sort_by(|a, b| a.resource.cmp(&b.resource));
    not_checked.sort_by(|a, b| a.resource.cmp(&b.resource));

    doc.conflicts = Checked::found(conflicts);
    doc.admission = Checked::found(admission);
    doc.not_checked = not_checked;
    doc.being_deleted = kix::plan::server::being_deleted(answers, |rid| {
        build.iter().find(|m| ResourceId::from_value(m) == *rid)
    });
    let left_behind = report.map(|r| &r.left_behind);
    doc.prune = Checked::found(prune_entries(checked, &prune_answers, left_behind));
}

/// Return the reason the plan document gives for a refused write, and the
/// admission webhook or policy that answered. A field ownership conflict is
/// listed apart from these.
pub(crate) fn admission_reason(refusal: &Refusal) -> (RefusalReason, Option<String>) {
    match refusal {
        Refusal::WebhookUnreachable { webhook, .. } => {
            (RefusalReason::WebhookUnreachable, webhook.clone())
        }
        Refusal::WebhookDenied { webhook, .. } => (RefusalReason::WebhookDenied, webhook.clone()),
        Refusal::PolicyDenied { policy, .. } => (RefusalReason::PolicyDenied, policy.clone()),
        Refusal::Invalid {
            immutable: true, ..
        } => (RefusalReason::ImmutableField, None),
        Refusal::Invalid { .. } => (RefusalReason::Invalid, None),
        Refusal::Forbidden { .. } => (RefusalReason::Forbidden, None),
        Refusal::NamespaceMissing { .. } => (RefusalReason::NamespaceMissing, None),
        Refusal::UnknownKind { .. } => (RefusalReason::UnknownKind, None),
        Refusal::Hydration { .. } => (RefusalReason::Decryption, None),
        Refusal::SopsNotFlat { .. } => (RefusalReason::SopsNotFlat, None),
        // `classify` lists a webhook without dry-run support as not checked,
        // so no such refusal reaches the document.
        Refusal::WebhookNoDryRun { webhook, .. } => (RefusalReason::Other, webhook.clone()),
        Refusal::Conflict { .. } | Refusal::Other { .. } => (RefusalReason::Other, None),
    }
}

/// Build the list of [`PruneEntry`] records for orphaned resources.
fn prune_entries(
    checked: &CheckedPlan,
    answers: &HashMap<ResourceId, PruneAnswer>,
    left_behind: Option<&HashMap<ResourceId, LeftBehind>>,
) -> Vec<PruneEntry> {
    let mut entries = orphan_entries(
        checked.orphans(),
        checked.flags().prune,
        answers,
        left_behind,
    );
    entries.extend(checked.shared_orphans().iter().map(|s| {
        PruneEntry::new(
            s.rid.display_id(),
            PruneFate::KeptShared,
            Some(s.describe()),
        )
    }));
    entries.sort_by(|a, b| a.resource.cmp(&b.resource));
    entries
}

/// Return the [`PruneEntry`] of each of `orphans` under prune policy
/// `policy`, with the dry run's `answers` and the objects `left_behind` that
/// each orphan's kind leaves on the cluster.
fn orphan_entries(
    orphans: &[ResourceId],
    policy: PrunePolicy,
    answers: &HashMap<ResourceId, PruneAnswer>,
    left_behind: Option<&HashMap<ResourceId, LeftBehind>>,
) -> Vec<PruneEntry> {
    orphans
        .iter()
        .map(|rid| {
            let mut entry = prune_entry(rid, policy, answers.get(rid));
            entry.left_behind = left_behind.and_then(|l| l.get(rid)).cloned();
            entry
        })
        .collect()
}

/// Return what a deploy with prune policy `policy` does with orphan `rid`,
/// given the dry run's `answer` for its delete.
pub(crate) fn prune_entry(
    rid: &ResourceId,
    policy: PrunePolicy,
    answer: Option<&PruneAnswer>,
) -> PruneEntry {
    let (fate, detail) = if lifecycle::never_pruned(rid.group_kind()) {
        (PruneFate::KeptNeverPruned, None)
    } else {
        match policy {
            PrunePolicy::Skip => (PruneFate::KeptSkipped, None),
            PrunePolicy::WarnOnly => (PruneFate::KeptWarnOnly, None),
            PrunePolicy::Delete => match answer {
                Some(PruneAnswer::KeptShared(why)) => (PruneFate::KeptShared, Some(why.clone())),
                Some(PruneAnswer::KeptChanged) => (
                    PruneFate::KeptChanged,
                    Some("changed since it was read; the next prune checks it again".into()),
                ),
                Some(PruneAnswer::Refused(why)) => (PruneFate::DeleteRefused, Some(why.clone())),
                Some(PruneAnswer::Deleted(_)) | None => (PruneFate::Delete, None),
            },
        }
    };
    let mut entry = PruneEntry::new(rid.display_id(), fate, detail);
    if fate == PruneFate::Delete
        && let Some(PruneAnswer::Deleted(wait)) = answer
    {
        entry.finalizers = wait.finalizers.clone();
        entry.deleting_since = wait.deleting_since.clone();
        entry.controllers = wait.controllers.iter().map(prune_controller).collect();
    }
    entry
}

/// Return what the plan document says about a controller Kix read.
fn prune_controller(c: &readiness::Controller) -> PruneController {
    let (state, detail) = match &c.state {
        ControllerState::Ready => (PruneControllerState::Ready, None),
        ControllerState::NotReady(why) => (PruneControllerState::NotReady, Some(why.clone())),
        ControllerState::Missing => (PruneControllerState::Missing, None),
        ControllerState::Unread(e) => (PruneControllerState::Unread, Some(e.clone())),
    };
    PruneController {
        resource: c.id.display_id(),
        state,
        detail,
    }
}

fn print_migrations(doc: &Plan, accepted: bool) {
    let pairs: Vec<plan::migrations::Replacement> = doc
        .migrations
        .items()
        .iter()
        .map(plan::migrations::Replacement::from)
        .collect();
    if pairs.is_empty() {
        return;
    }
    println!();
    print!("{}", plan::migrations::plan(&pairs, accepted));
}

/// Print the human-readable plan summary and details.
///
/// When `verbose` is `true`, lists each changed resource and field.
pub(crate) fn print_text(p: &Planned, doc: &Plan, verbose: bool) {
    let fate = plan::orphans_fate(
        p.checked.flags(),
        p.client().is_some(),
        &p.build.graph().cluster_name,
    );

    // Say where the extra work in this plan came from before the changes and
    // orphans it explains. Without this the reader sees a deploy of an
    // unchanged config proposing changes, and has no way to tell why.
    if !p.baseline.failed().is_empty() {
        let names: Vec<&str> = p
            .baseline
            .failed()
            .consumed
            .iter()
            .map(String::as_str)
            .collect();
        crate::say!(
            "  {} reconciling what {} left behind ({})",
            output::yellow("!"),
            if names.len() == 1 {
                "a failed deploy".to_string()
            } else {
                format!("{} failed deploys", names.len())
            },
            names.join(", "),
        );
    }

    // Shared orphans are listed with the prune section of `render::render_text`.
    plan::print_checked(&p.checked, &fate, verbose);

    output::progress_text(&render::render_text(doc));
}

fn markdown(p: &Planned, doc: &Plan) -> String {
    let mut out = plan::render_package_diff_markdown(p.checked.pkg_diff()).replacen(
        "### kix diff",
        "### kix plan",
        1,
    );
    if !doc.migrations.items().is_empty() {
        use std::fmt::Write;
        let _ = writeln!(
            out,
            "#### Stateful migrations detected ({})",
            doc.migrations.items().len()
        );
        let _ = writeln!(out);
        for m in doc.migrations.items() {
            let _ = writeln!(
                out,
                "- **{}**: `{}` → `{}` ({})",
                m.slot, m.source, m.target, m.reason
            );
        }
        let _ = writeln!(out);
    }
    out.push_str(&render::render_markdown(doc));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use kix::cluster::preview::DeleteWait;

    /// What a deploy prints before it asks to go on (`deploy::preview`,
    /// then `deploy::confirm`) is the text of the plan document, and the
    /// document's prune entries carry what the dry run found a prune leaves
    /// behind, so the warning comes before the prompt.
    #[test]
    fn the_plan_before_the_prompt_names_objects_left_behind() {
        let crd = ResourceId::new(
            "apiextensions.k8s.io",
            "CustomResourceDefinition",
            kix::manifest::types::CLUSTER_SCOPED,
            "challenges.acme.cert-manager.io",
        );
        let left = LeftBehind {
            kind: "Challenge.acme.cert-manager.io".into(),
            count: 1,
            with_finalizers: 1,
            objects: vec![kix::plan::document::LeftObject {
                resource: "Challenge.acme.cert-manager.io/c@app".into(),
                finalizers: vec!["acme.cert-manager.io/finalizer".into()],
            }],
        };
        let found = HashMap::from([(crd.clone(), left)]);
        let entries = orphan_entries(
            std::slice::from_ref(&crd),
            PrunePolicy::Delete,
            &HashMap::new(),
            Some(&found),
        );
        let graph = kix::eval::store_graph::StoreGraph::empty("c");
        let mut doc = Plan::new(
            crate::plan::kix_build(),
            MadeBy::DryRun,
            "c",
            Build::of(&graph),
            &kix::plan::diff_graphs(&graph, &graph),
            Detail::Plain,
            &[],
            NotCheckedReason::ReadOnly,
        );
        doc.flags = Some(PlanFlags {
            prune: PrunePolicy::Delete,
            reconcile: false,
            force_conflicts: false,
            accept_migrations: false,
        });
        doc.prune = Checked::found(entries);
        let text = plan::render::render_text(&doc);
        assert!(
            text.contains("this prune leaves 1 Challenge.acme.cert-manager.io object"),
            "{text}"
        );
        assert!(
            text.contains(
                "Challenge.acme.cert-manager.io/c@app (finalizers: acme.cert-manager.io/finalizer)"
            ),
            "{text}"
        );
        let none = orphan_entries(
            std::slice::from_ref(&crd),
            PrunePolicy::Delete,
            &HashMap::new(),
            None,
        );
        assert!(none[0].left_behind.is_none());
    }

    /// A delete's entry carries what the dry run found it will wait for. An
    /// orphan that the deploy keeps carries none of it.
    #[test]
    fn a_prune_entry_says_what_its_delete_waits_for() {
        let rid = ResourceId::new("keda.sh", "ScaledObject", "app", "worker");
        let answer = PruneAnswer::Deleted(DeleteWait {
            finalizers: vec!["finalizer.keda.sh".into()],
            deleting_since: Some("2026-11-24T15:54:00Z".into()),
            controllers: vec![readiness::Controller {
                id: ResourceId::new("apps", "Deployment", "keda", "keda-operator"),
                state: ControllerState::NotReady("0/1 ready".into()),
            }],
        });
        let entry = prune_entry(&rid, PrunePolicy::Delete, Some(&answer));
        assert_eq!(entry.fate, PruneFate::Delete);
        assert_eq!(entry.finalizers, ["finalizer.keda.sh"]);
        assert_eq!(
            entry.deleting_since.as_deref(),
            Some("2026-11-24T15:54:00Z")
        );
        assert_eq!(
            entry.controllers,
            [PruneController {
                resource: "Deployment.apps/keda-operator@keda".into(),
                state: PruneControllerState::NotReady,
                detail: Some("0/1 ready".into()),
            }]
        );

        let kept = prune_entry(&rid, PrunePolicy::WarnOnly, Some(&answer));
        assert_eq!(kept.fate, PruneFate::KeptWarnOnly);
        assert!(kept.finalizers.is_empty() && kept.controllers.is_empty());
        assert_eq!(kept.deleting_since, None);
        let plain = prune_entry(&rid, PrunePolicy::Delete, None);
        assert!(plain.finalizers.is_empty() && plain.controllers.is_empty());
    }
}
