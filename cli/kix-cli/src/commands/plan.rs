//! `kix plan`: the deploy pipeline as a server-side dry run.
//!
//! The plan is made by the code that deploys. [`prepare`] builds and runs
//! [`kix::plan::Planner`], which computes the deploy's actions; [`dry_run`]
//! runs the engine over them with every write sent as `dryRun=All`, so the
//! apiserver answers for each object; [`document`] turns those answers into
//! the [`Plan`] document `kix diff` also emits. `kix deploy` runs the same
//! three steps before it asks for confirmation.

use std::collections::{HashMap, HashSet};
use std::io::IsTerminal;
use std::path::Path;
use std::sync::{Arc, Mutex};

use miette::{Result, miette};
use serde_json::Value;

use kix::build_source::InstallableBuild;
use kix::cluster::preview::{DryRunAnswer, DryRunOutcome, PruneAnswer, Refusal};
use kix::cluster::readiness;
use kix::cluster::scheduler::{self, OnErrorPolicy, PrunePolicy, SchedulerConfig};
use kix::cluster::stream::{
    CancelReason, DeployEvent, DeployObserver, NodeId, TransitionKind, Verdict,
};
use kix::cluster::watchdog::StallPolicy;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::lifecycle;
use kix::manifest::types::ResourceId;
use kix::plan::document::{
    AdmissionRefusal, Build, Checked, Conflict, ConflictOwner, DeployedBuild, Detail, MadeBy,
    NotCheckedReason, Plan, PlanFlags, PruneEntry, PruneFate, PruneModeFlag, RefusalReason,
    UncheckedObject, UncheckedReason,
};
use kix::plan::server::comparable;
use kix::plan::{ManifestIndex, OldSide, PlanEvent, Planned, Planner, Target};

use crate::cli::{OutputFormat, PlanArgs, PruneMode};
use crate::output;
use crate::plan::{self, render};

use super::CommandContext;

/// Exit status when the deploy would stop: a refused write, or a stateful
/// migration not accepted with `--accept-migrations`.
pub(crate) const EXIT_WOULD_STOP: i32 = 3;
/// Exit status when the deploy would change something.
const EXIT_CHANGES: i32 = 2;

pub fn run(args: &PlanArgs, save: Option<&Path>, ctx: &mut CommandContext) -> Result<()> {
    let format = output::format();
    if matches!(format, OutputFormat::Json | OutputFormat::Yaml) {
        return Err(miette!(
            "kix plan prints text or Markdown. To keep the plan as data, write it with \
             --save FILE.{}: `kix deploy --plan` reads that file, and `zstd -dc FILE | jq -s '.[0]'` \
             prints its header",
            kix::plan::file::EXTENSION
        ));
    }
    let Some(mut p) = prepare(args, flags_of(args), ctx)? else {
        // A plan file needs a plan, and a caller that asked for one must
        // not find exit 0 and no file.
        if let Some(path) = save {
            return Err(miette!(
                "the build has no resources, so there is no plan to save; {} was not written",
                path.display()
            ));
        }
        return Ok(());
    };
    // A plan decrypts no SOPS file the build carries: those Secrets get
    // placeholder values, so planning before anyone has approved reads no
    // secret.
    let report = match p.client.clone() {
        Some(client) => Some(dry_run(&mut p, true, client, ctx)?),
        None => None,
    };
    let doc = document(&mut p, report.as_ref(), save.is_some());
    if let Some(path) = save {
        let sha256 = plan::save(doc.clone(), p.build.graph(), path)?;
        crate::esay!("Saved the plan to {} (sha256:{sha256})", path.display());
    }

    match format {
        OutputFormat::Json | OutputFormat::Yaml => unreachable!("refused above"),
        OutputFormat::Markdown => print!("{}", markdown(&p, &doc)),
        OutputFormat::Text => {
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
        std::process::exit(EXIT_WOULD_STOP);
    }
    if doc.has_changes() {
        std::process::exit(EXIT_CHANGES);
    }
    Ok(())
}

/// Extract [`PlanFlags`] from CLI arguments.
pub(crate) fn flags_of(args: &PlanArgs) -> PlanFlags {
    PlanFlags {
        prune: args.prune,
        prune_mode: args.prune_mode.map(|m| match m {
            PruneMode::Default => PruneModeFlag::Default,
            PruneMode::No => PruneModeFlag::No,
        }),
        reconcile: args.reconcile,
        force_conflicts: args.force_conflicts,
        accept_migrations: args.accept_migrations,
    }
}

/// Select the baseline source (`OldSide`) for planning: the local cache under
/// `--current-activation`, or the live cluster otherwise.
fn old_side(args: &PlanArgs, ctx: &CommandContext) -> OldSide {
    if args.current_activation {
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
        .runtime
        .block_on(Planner::new(flags, &report).run(build, &old_side(args, ctx)))
        .map_err(|e| miette!("{e}"))?;
    Ok(Some(planned))
}

/// Load the target build from `--bundle` or by building the flake into the
/// local Nix store.
///
/// Rejects builds pinned to a pre-migration `kixpkgs` revision that still
/// renders Kix's CRDs under the retired API group.
fn new_build(args: &PlanArgs, ctx: &CommandContext) -> Result<InstallableBuild> {
    let build = match &args.bundle {
        Some(path) => {
            crate::say!("Reading bundle {}...", path.display());
            kix_bundle::read_build(path, &args.deployed_bundles, &args.cluster)
                .map_err(|e| miette::miette!("{e}"))?
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
    /// Kinds the apiserver serves.
    pub served_kinds: HashSet<String>,
}

/// Run the deploy's engine plan with every write sent as a dry run.
///
/// The engine runs with `--on-error continue`, and under dry run it still
/// tries the dependents of a refused node, so one refused write does not hide
/// the answers for the rest. Nothing is persisted: every write goes with
/// `dryRun=All` and the Activation record's lifecycle writes are skipped
/// ([`kix::plan::CheckedPlan::dry_run`]).
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
    let p = &*p;
    ctx.runtime.block_on(async {
        let target = Target::connect(client, sops)
            .await
            .map_err(|e| miette!("{e}"))?;
        kix::legacy_domain::check_discovery(target.discovery()).map_err(|e| miette!("{e}"))?;
        let served_kinds: HashSet<String> = target
            .discovery()
            .iter()
            .map(|(ar, _)| ar.kind.clone())
            .collect();

        let config = SchedulerConfig {
            timeout: readiness::DEFAULT_TIMEOUT,
            on_error: OnErrorPolicy::Continue,
            cancel: kix::cluster::cancel::CancelToken::new(),
            concurrency: scheduler::CONCURRENCY,
            stall: StallPolicy::from_env(),
            rerun_failed: true,
            check_unchanged: true,
            names_flags: true,
        };
        let cancel = config.cancel.clone();
        cancel.cancel_on_interrupt();

        let writes = p
            .checked
            .plan()
            .nodes()
            .iter()
            .filter(|n| !matches!(n.kind, TransitionKind::Skip))
            .count();
        let observer = Arc::new(DryRunObserver::new(writes));
        let (result, answers) = p.checked.dry_run(target, config, observer.clone()).await;
        // Cancelling the token ends its interrupt watcher, so Ctrl-C at the
        // deploy's confirmation exits the process.
        let interrupted = cancel.is_cancelled();
        cancel.cancel();
        observer.finish();
        if interrupted {
            return Err(miette!("plan interrupted"));
        }
        if let Err(e) = &result
            && !matches!(e, scheduler::DeployError::NodesFailed { .. })
        {
            return Err(miette!("the dry run stopped: {e}"));
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
            served_kinds,
        })
    })
}

#[derive(Default)]
struct Seen {
    failed: HashMap<ResourceId, String>,
    cancelled: HashMap<ResourceId, Option<ResourceId>>,
    done: usize,
}

/// Collects the engine's verdicts in a dry run, and shows a progress line
/// on stderr.
struct DryRunObserver {
    seen: Mutex<Seen>,
    bar: Option<indicatif::ProgressBar>,
}

impl DryRunObserver {
    fn new(writes: usize) -> Self {
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
        if matches!(kind, TransitionKind::Delete | TransitionKind::Skip) || !verdict.is_terminal() {
            return;
        }
        let Ok(mut seen) = self.seen.lock() else {
            return;
        };
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
        seen.done += 1;
        if let Some(bar) = &self.bar {
            bar.set_position(seen.done as u64);
        }
    }
}

/// Build the [`Plan`] document and overlay the apiserver's dry-run answers onto
/// the package diff ([`Planned::overlay`]).
///
/// When `manifests` is `true`, includes full manifest diffs (`Detail::Manifests`)
/// as required when saving a plan file; otherwise uses `Detail::Plain`.
pub(crate) fn document(p: &mut Planned, report: Option<&DryRunReport>, manifests: bool) -> Plan {
    let connected = p.client.is_some();
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

    let mut conflicts = Vec::new();
    let mut admission = Vec::new();
    let mut not_checked = Vec::new();
    let mut prune_answers: HashMap<ResourceId, PruneAnswer> = HashMap::new();
    let crds = BuildCrds::of(p.new_manifests());
    let manifests: HashMap<ResourceId, &Value> = p
        .new_manifests()
        .iter()
        .map(|m| (ResourceId::from_value(m), m))
        .collect();
    let built_namespaces: HashSet<String> = p
        .new_manifests()
        .iter()
        .map(ResourceId::from_value)
        .filter(|rid| rid.kind == "Namespace")
        .map(|rid| rid.name)
        .collect();
    let served = report.map(|r| &r.served_kinds);
    let changed_crds = changed_crds(answers);
    // An immutable-field refusal is followed by a recreate when the engine
    // may delete the object; the deploy recreates it rather than stopping.
    let recreated: HashSet<&ResourceId> = answers
        .iter()
        .filter(|a| matches!(a.outcome, DryRunOutcome::Recreated { .. }))
        .map(|a| &a.rid)
        .collect();

    for answer in answers {
        let resource = answer.rid.display_id();
        let refusal = match &answer.outcome {
            DryRunOutcome::Refused(_) if recreated.contains(&answer.rid) => continue,
            DryRunOutcome::Refused(r) => r,
            DryRunOutcome::Pruned(a) => {
                prune_answers.insert(answer.rid.clone(), a.clone());
                continue;
            }
            DryRunOutcome::Applied(_) | DryRunOutcome::Recreated { .. } => continue,
        };
        let refused = |reason, webhook: Option<String>, message: String| AdmissionRefusal {
            resource: resource.clone(),
            reason,
            webhook,
            message,
        };
        match refusal {
            Refusal::Conflict { owners, message } => conflicts.push(Conflict {
                resource: resource.clone(),
                owners: owners
                    .iter()
                    .map(|o| ConflictOwner {
                        manager: o.manager.clone(),
                        fields: o.fields.clone(),
                    })
                    .collect(),
                message: message.clone(),
            }),
            Refusal::WebhookNoDryRun { message, .. } => not_checked.push(UncheckedObject {
                resource: resource.clone(),
                reason: UncheckedReason::WebhookNoDryRun,
                detail: message.clone(),
            }),
            Refusal::WebhookUnreachable {
                webhook,
                service,
                message,
            } => {
                if refusal
                    .unreachable_service_written(|rid| manifests.contains_key(rid))
                    .is_some()
                {
                    not_checked.push(UncheckedObject {
                        resource: resource.clone(),
                        reason: UncheckedReason::WebhookServiceWrittenByThisDeploy,
                        detail: format!(
                            "admission webhook {} could not reach {}, which this deploy writes",
                            webhook.as_deref().unwrap_or("?"),
                            service.display_id()
                        ),
                    })
                } else {
                    admission.push(refused(
                        RefusalReason::Other,
                        webhook.clone(),
                        message.clone(),
                    ))
                }
            }
            Refusal::UnknownKind { .. } | Refusal::Invalid { .. } | Refusal::Other { .. }
                if manifests
                    .get(&answer.rid)
                    .and_then(|m| crd_key(m))
                    .is_some_and(|k| changed_crds.contains(&k)) =>
            {
                not_checked.push(UncheckedObject {
                    resource: resource.clone(),
                    reason: UncheckedReason::CrdChangedByThisDeploy,
                    detail: "checked against the CRD now on the cluster, which this deploy \
                             changes"
                        .into(),
                })
            }
            Refusal::UnknownKind { kind }
                if !served.is_some_and(|s| s.contains(kind))
                    && crds.brings(manifests.get(&answer.rid).copied()) =>
            {
                not_checked.push(UncheckedObject {
                    resource: resource.clone(),
                    reason: UncheckedReason::CrdCreatedByThisDeploy,
                    detail: format!("kind {kind} is served once this deploy installs its CRD"),
                })
            }
            Refusal::NamespaceMissing { namespace, .. } if built_namespaces.contains(namespace) => {
                not_checked.push(UncheckedObject {
                    resource: resource.clone(),
                    reason: UncheckedReason::NamespaceCreatedByThisDeploy,
                    detail: format!("namespace {namespace} is created by this deploy"),
                })
            }
            Refusal::WebhookDenied { webhook, message } => admission.push(refused(
                RefusalReason::WebhookDenied,
                webhook.clone(),
                message.clone(),
            )),
            Refusal::PolicyDenied { policy, message } => admission.push(refused(
                RefusalReason::PolicyDenied,
                policy.clone(),
                message.clone(),
            )),
            Refusal::Invalid { immutable, message } => admission.push(refused(
                if *immutable {
                    RefusalReason::ImmutableField
                } else {
                    RefusalReason::Invalid
                },
                None,
                message.clone(),
            )),
            Refusal::Forbidden { message } => {
                admission.push(refused(RefusalReason::Forbidden, None, message.clone()))
            }
            Refusal::NamespaceMissing { message, .. } => admission.push(refused(
                RefusalReason::NamespaceMissing,
                None,
                message.clone(),
            )),
            Refusal::UnknownKind { .. } => {
                admission.push(refused(RefusalReason::UnknownKind, None, refusal.message()))
            }
            Refusal::Hydration { message } => {
                admission.push(refused(RefusalReason::Decryption, None, message.clone()))
            }
            Refusal::Other { message } => {
                admission.push(refused(RefusalReason::Other, None, message.clone()))
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
    doc.drift = match drift {
        Some(drift) => Checked::found(drift),
        None => Checked::not_checked(NotCheckedReason::DeployedBuildUnavailable),
    };
    doc.prune = Checked::found(prune_entries(p, &prune_answers));
    // A custom resource whose CRD this deploy changes was checked against the
    // CRD on the cluster now, which prunes the fields the new CRD adds.
    doc.not_kept = kix::plan::server::not_kept(answers, |rid| {
        manifests
            .get(rid)
            .and_then(|m| crd_key(m))
            .is_some_and(|k| changed_crds.contains(&k))
    });
    doc
}

/// Return the `(group, kind)` pair for `manifest`.
fn crd_key(manifest: &Value) -> Option<(String, String)> {
    let kind = manifest.get("kind").and_then(Value::as_str)?;
    let api_version = manifest.get("apiVersion").and_then(Value::as_str)?;
    let group = api_version.split_once('/').map_or("", |(g, _)| g);
    Some((group.to_string(), kind.to_string()))
}

/// Return the `(group, kind)` pair defined by a CRD manifest.
fn defined_by(crd: &Value) -> Option<(String, String)> {
    let group = crd.pointer("/spec/group").and_then(Value::as_str)?;
    let kind = crd.pointer("/spec/names/kind").and_then(Value::as_str)?;
    Some((group.to_string(), kind.to_string()))
}

/// Return the `(group, kind)` pairs whose CRDs are created or modified in
/// `answers`.
///
/// Custom resources of these kinds were dry-run validated against the older CRD
/// currently on the cluster, so validation refusals on them are reported as
/// `CrdChangedByThisDeploy` rather than hard admission failures.
fn changed_crds(answers: &[DryRunAnswer]) -> HashSet<(String, String)> {
    answers
        .iter()
        .filter(|a| a.rid.kind == "CustomResourceDefinition")
        .filter_map(|a| match &a.outcome {
            DryRunOutcome::Applied(p) => {
                let unchanged = p
                    .live
                    .as_ref()
                    .is_some_and(|live| comparable(live) == comparable(&p.result));
                (!unchanged).then(|| defined_by(&p.result)).flatten()
            }
            _ => None,
        })
        .collect()
}

/// Custom resource kinds and API groups introduced by the build, either
/// directly as `CustomResourceDefinition` manifests or via operator import
/// markers.
struct BuildCrds {
    kinds: HashSet<(String, String)>,
    groups: HashSet<String>,
}

impl BuildCrds {
    fn of(manifests: &[Value]) -> Self {
        let kinds = manifests
            .iter()
            .filter(|m| m.get("kind").and_then(Value::as_str) == Some("CustomResourceDefinition"))
            .filter_map(defined_by)
            .collect();
        let groups = manifests
            .iter()
            .filter_map(|m| readiness::import_target_from_manifest(m).ok().flatten())
            .filter(|t| t.kind == "CustomResourceDefinition")
            .filter_map(|t| t.name.split_once('.').map(|(_, group)| group.to_string()))
            .collect();
        BuildCrds { kinds, groups }
    }

    /// Return `true` if `manifest` belongs to a CRD kind or API group
    /// introduced by this build.
    fn brings(&self, manifest: Option<&Value>) -> bool {
        manifest
            .and_then(crd_key)
            .is_some_and(|key| self.groups.contains(&key.0) || self.kinds.contains(&key))
    }
}

/// Build the list of [`PruneEntry`] records for orphaned resources.
fn prune_entries(p: &Planned, answers: &HashMap<ResourceId, PruneAnswer>) -> Vec<PruneEntry> {
    let policy = p.checked.flags().prune_policy();
    let mut entries: Vec<PruneEntry> = p
        .checked
        .orphans()
        .iter()
        .map(|rid| {
            let (fate, detail) = if lifecycle::never_pruned(&rid.kind) {
                (PruneFate::KeptNeverPruned, None)
            } else {
                match policy {
                    PrunePolicy::Skip => (PruneFate::KeptSkipped, None),
                    PrunePolicy::WarnOnly => (PruneFate::KeptWarnOnly, None),
                    PrunePolicy::Delete => match answers.get(rid) {
                        Some(PruneAnswer::KeptShared(why)) => {
                            (PruneFate::KeptShared, Some(why.clone()))
                        }
                        Some(PruneAnswer::KeptChanged) => (
                            PruneFate::KeptChanged,
                            Some(
                                "changed since it was read; the next prune checks it again".into(),
                            ),
                        ),
                        Some(PruneAnswer::Refused(why)) => {
                            (PruneFate::DeleteRefused, Some(why.clone()))
                        }
                        Some(PruneAnswer::Deleted) | None => (PruneFate::Delete, None),
                    },
                }
            };
            PruneEntry {
                resource: rid.display_id(),
                fate,
                detail,
            }
        })
        .collect();
    entries.extend(p.checked.shared_orphans().iter().map(|s| PruneEntry {
        resource: s.rid.display_id(),
        fate: PruneFate::KeptShared,
        detail: Some(s.describe()),
    }));
    entries.sort_by(|a, b| a.resource.cmp(&b.resource));
    entries
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
    plan::print_package_plan(p.checked.pkg_diff(), verbose);
    plan::print_plan_summary(p.checked.pkg_diff());

    // Jobs under the rerun rule that changed: the engine deletes and
    // recreates them, so the preview says so.
    let reruns: Vec<String> = p
        .checked
        .plan()
        .nodes()
        .iter()
        .filter(|n| matches!(n.kind, TransitionKind::Recreate))
        .map(|n| match &n.id {
            NodeId::Resource(rid) => rid.to_string(),
            NodeId::Synthetic(s) => s.clone(),
        })
        .collect();
    if !reruns.is_empty() {
        crate::say!(
            "  {} {} Job(s) with {} will be deleted and recreated so they run again: {}",
            output::yellow("↻"),
            reruns.len(),
            kix::manifest::keys::RERUN,
            reruns.join(", "),
        );
    }

    let deletes = p.checked.flags().prune_policy() == PrunePolicy::Delete;
    let fate = if p.checked.flags().prune_mode == Some(PruneModeFlag::No) {
        "still running on the cluster (`--prune-mode no`, not deleted)".to_string()
    } else if deletes && p.client.is_none() {
        // `--current-activation` has not contacted the cluster, so it
        // cannot yet tell which orphans another Kix cluster deploys.
        "to be deleted after the apply (`--prune`) except any still deployed by \
         another Kix cluster (checked once connected)"
            .to_string()
    } else if deletes {
        "to be deleted after the apply (`--prune`)".to_string()
    } else {
        plan::kept_orphans_fate(&p.build.graph().cluster_name)
    };
    // Shared orphans are listed with the prune section of `render::render_text`.
    output::progress_text(&plan::render_plan_orphans(p.checked.orphans(), &fate));

    // Where the extra work in this plan came from. Without this the reader
    // sees a deploy of an unchanged config proposing changes, and has no way
    // to tell why.
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
    use kix::cluster::apply::ApplyPreview;
    use serde_json::json;

    fn crd(group: &str, kind: &str, version: &str) -> Value {
        json!({
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {"name": format!("{}s.{group}", kind.to_lowercase())},
            "spec": {"group": group, "names": {"kind": kind}, "versions": [{"name": version}]},
        })
    }

    fn applied(manifest: &Value, live: Option<Value>) -> DryRunAnswer {
        DryRunAnswer {
            rid: ResourceId::from_value(manifest),
            outcome: DryRunOutcome::Applied(Box::new(ApplyPreview {
                live,
                result: manifest.clone(),
                not_kept: Vec::new(),
            })),
        }
    }

    /// Verify that [`changed_crds`] includes only CRDs modified by the dry run.
    #[test]
    fn a_crd_the_deploy_changes_marks_its_kind() {
        let new = crd("example.com", "Widget", "v2");
        let same = crd("example.com", "Gadget", "v1");
        let answers = vec![
            applied(&new, Some(crd("example.com", "Widget", "v1"))),
            applied(&same, Some(same.clone())),
        ];
        let changed = changed_crds(&answers);
        assert!(changed.contains(&("example.com".into(), "Widget".into())));
        assert!(!changed.contains(&("example.com".into(), "Gadget".into())));
    }

    /// Verify that [`BuildCrds::brings`] matches both API group and kind.
    #[test]
    fn build_crds_match_group_and_kind() {
        let crds = BuildCrds::of(&[crd("example.com", "Widget", "v1")]);
        let widget = |api: &str| json!({"apiVersion": api, "kind": "Widget"});
        assert!(crds.brings(Some(&widget("example.com/v1"))));
        assert!(!crds.brings(Some(&widget("other.io/v1"))));
    }
}
