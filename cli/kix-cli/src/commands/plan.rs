//! `kix plan`: the deploy pipeline as a server-side dry run.
//!
//! The plan is made by the code that deploys. [`super::deploy::prepare`]
//! builds and computes the deploy's actions; [`dry_run`] runs the engine
//! over them with every write sent as `dryRun=All`, so the apiserver answers
//! for each object; [`document`] turns those answers into the [`Plan`]
//! document `kix diff` also emits. `kix deploy` runs the same three steps
//! before it asks for confirmation.

use std::collections::{HashMap, HashSet};
use std::io::IsTerminal;
use std::sync::{Arc, Mutex};

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::cluster::fetch;
use kix::cluster::ops::{ClusterOps, KubeOps, KubeOpsConfig};
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

use crate::cli::{Detail as DetailArg, OutputFormat, PlanArgs, PruneMode};
use crate::output;
use crate::plan::document::{
    AdmissionRefusal, Build, Checked, Conflict, ConflictOwner, DeployedBuild, Detail, MadeBy,
    NotCheckedReason, Plan, PlanFlags, PruneEntry, PruneFate, PruneModeFlag, RefusalReason,
    UncheckedObject, UncheckedReason,
};
use crate::plan::server::{Overlay, comparable};
use crate::plan::{self, ManifestIndex, render};

use super::CommandContext;
use super::deploy::{self, Prepared};

/// Exit status when the deploy would stop: a refused write, or a stateful
/// migration not accepted with `--accept-migrations`.
const EXIT_WOULD_STOP: i32 = 3;
/// Exit status when the deploy would change something.
const EXIT_CHANGES: i32 = 2;

pub fn run(args: &PlanArgs, detail: DetailArg, ctx: &mut CommandContext) -> Result<()> {
    let format = ctx.output_format(OutputFormat::Text);
    if format != OutputFormat::Text {
        output::progress_to_stderr();
    }
    let Some(mut p) = deploy::prepare(args, ctx)? else {
        return Ok(());
    };
    let report = match &p.pre_client {
        Some(client) => Some(dry_run(&p, args, client.clone(), ctx)?),
        None => None,
    };
    let doc = document(&mut p, report.as_ref(), args, detail);

    match format {
        OutputFormat::Json => println!("{}", doc.to_json()),
        OutputFormat::Yaml => print!("{}", doc.to_yaml().into_diagnostic()?),
        OutputFormat::Markdown => print!("{}", markdown(&p, &doc)),
        OutputFormat::Text => {
            if !ctx.global.quiet {
                print_migrations(&doc, args);
                // A plan exists to be read, so it always shows each change.
                print_text(&p, &doc, args, true);
            }
        }
    }

    let migrations_refused = !doc.migrations.items().is_empty() && !args.accept_migrations;
    if doc.stops() || migrations_refused {
        std::process::exit(EXIT_WOULD_STOP);
    }
    if doc.has_changes() {
        std::process::exit(EXIT_CHANGES);
    }
    Ok(())
}

fn flags_of(args: &PlanArgs) -> PlanFlags {
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

/// The graphs' manifests, with each object the apiserver answered for shown
/// as the live object and the dry-run result. A refused write keeps the
/// build's manifest, which is what the deploy would send.
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
            } => (live.as_ref(), Some(result)),
            _ => continue,
        };
        index.answered(&answer.rid, live.map(comparable), result.map(comparable));
    }
    index
}

/// What the engine and the apiserver said during a dry run.
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
/// the answers for the rest. Nothing is persisted: `KubeOps` sends every write with
/// `dryRun=All` and skips the Activation record's lifecycle writes.
pub(crate) fn dry_run(
    p: &Prepared,
    args: &PlanArgs,
    client: kube::Client,
    ctx: &CommandContext,
) -> Result<DryRunReport> {
    let quiet = ctx.global.quiet;
    ctx.runtime.block_on(async {
        let discovery = fetch::discover_resources(&client)
            .await
            .map_err(|e| miette!("{e}"))?;
        kix::legacy_domain::check_cluster(
            &discovery
                .iter()
                .filter(|(ar, _)| lifecycle::is_record_kind(&ar.kind))
                .map(|(ar, _)| ar.group.as_str())
                .collect::<Vec<_>>(),
        )
        .map_err(|e| miette!("{e}"))?;
        let served_kinds: HashSet<String> =
            discovery.iter().map(|(ar, _)| ar.kind.clone()).collect();

        let ops = Arc::new(KubeOps::new(
            client,
            Arc::new(tokio::sync::RwLock::new(discovery)),
            KubeOpsConfig {
                cluster_name: p.cluster.clone(),
                activation_name: p.activation_name.clone(),
                activation_identity_hash: p.activation_identity_hash.clone(),
                force_conflicts: args.force_conflicts,
                dry_run: true,
                ..Default::default()
            },
        ));
        let config = SchedulerConfig {
            timeout: readiness::DEFAULT_TIMEOUT,
            on_error: OnErrorPolicy::Continue,
            prune: deploy::prune_policy_for(args),
            cancel: kix::cluster::cancel::CancelToken::new(),
            dry_run: true,
            concurrency: scheduler::CONCURRENCY,
            stall: StallPolicy::from_env(),
            rerun_failed: true,
        };
        config.cancel.cancel_on_interrupt();

        let writes = p
            .plan
            .nodes
            .iter()
            .filter(|n| !matches!(n.kind, TransitionKind::Skip))
            .count();
        let observer = Arc::new(PlanObserver::new(writes, quiet));
        let dyn_ops: Arc<dyn ClusterOps> = ops.clone();
        let result = scheduler::run_deploy(
            dyn_ops,
            p.plan.clone(),
            &p.orphan_rids,
            &p.old_manifests,
            &config,
            observer.clone(),
        )
        .await;
        // Cancelling the token ends its interrupt watcher, so Ctrl-C at the
        // deploy's confirmation exits the process.
        let interrupted = config.cancel.is_cancelled();
        config.cancel.cancel();
        observer.finish();
        if interrupted {
            return Err(miette!("plan interrupted"));
        }
        if let Err(e) = &result
            && !matches!(e, scheduler::DeployError::NodesFailed { .. })
        {
            return Err(miette!("the dry run stopped: {e}"));
        }

        let answers = ops.take_dry_run_answers();
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

/// Collects the engine's verdicts, and shows a progress line on stderr.
struct PlanObserver {
    seen: Mutex<Seen>,
    bar: Option<indicatif::ProgressBar>,
}

impl PlanObserver {
    fn new(writes: usize, quiet: bool) -> Self {
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
        PlanObserver {
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

impl DeployObserver for PlanObserver {
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

/// Make the plan document, and overlay the apiserver's answers on
/// `p.pkg_diff`, which the text renderers read.
pub(crate) fn document(
    p: &mut Prepared,
    report: Option<&DryRunReport>,
    args: &PlanArgs,
    detail: DetailArg,
) -> Plan {
    let connected = p.pre_client.is_some();
    let made_by = if connected {
        MadeBy::DryRun
    } else {
        MadeBy::Builds
    };
    // Without the deployed build's manifests (the old side was rebuilt from
    // the live objects) a commit's change and drift look the same.
    // A first deploy has no deployed build: every change is intended.
    let first_deploy = p.active_hash.is_none() && p.active_manifests.is_empty();
    let deployed: Option<HashMap<ResourceId, &Value>> = (p.old_graph.is_some() || first_deploy)
        .then(|| {
            p.active_manifests
                .iter()
                .map(|m| (ResourceId::from_value(m), m))
                .collect()
        });
    let has_deployed = deployed.is_some();
    let answers: &[DryRunAnswer] = report.map(|r| r.answers.as_slice()).unwrap_or(&[]);
    let drift = Overlay {
        new_graph: &p.new_graph,
        deployed,
    }
    .apply(&mut p.pkg_diff, answers);

    // Built only for `--detail manifests`. Without the deployed build the
    // old side is rebuilt from the old manifests, as `deploy::prepare` does.
    let rebuilt;
    let index = if detail == DetailArg::Manifests {
        let old = match &p.old_graph {
            Some(old) => old,
            None => {
                rebuilt = StoreGraph::synthesize(&p.old_manifests, &p.new_graph);
                &rebuilt
            }
        };
        Some(manifest_index(old, &p.new_graph, answers))
    } else {
        None
    };
    let detail = match (detail, &index) {
        (_, Some(index)) => Detail::Manifests(index),
        (DetailArg::Fields | DetailArg::Manifests, None) => Detail::Fields,
        (DetailArg::Plain, None) => Detail::Plain,
    };

    let mut doc = Plan::new(
        made_by,
        &p.cluster,
        Build::of(&p.new_graph),
        &p.pkg_diff,
        detail,
        &p.migration_pairs,
        NotCheckedReason::BuildsOnly,
    );
    doc.deployed = p.active.as_ref().map(|a| DeployedBuild {
        activation: a.name.clone(),
        identity_hash: a.identity_hash.clone(),
        store_path: a.built_via.clone(),
    });
    doc.flags = Some(flags_of(args));
    if !connected {
        return doc;
    }

    let mut conflicts = Vec::new();
    let mut admission = Vec::new();
    let mut not_checked = Vec::new();
    let mut prune_answers: HashMap<ResourceId, PruneAnswer> = HashMap::new();
    let crds = BuildCrds::of(&p.new_manifests);
    let manifests: HashMap<ResourceId, &Value> = p
        .new_manifests
        .iter()
        .map(|m| (ResourceId::from_value(m), m))
        .collect();
    let built_namespaces: HashSet<String> = p
        .new_manifests
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
    doc.drift = if has_deployed {
        Checked::found(drift)
    } else {
        Checked::not_checked(NotCheckedReason::DeployedBuildUnavailable)
    };
    doc.prune = Checked::found(prune_entries(p, args, &prune_answers));
    doc
}

/// The API group and kind a manifest is of.
fn crd_key(manifest: &Value) -> Option<(String, String)> {
    let kind = manifest.get("kind").and_then(Value::as_str)?;
    let api_version = manifest.get("apiVersion").and_then(Value::as_str)?;
    let group = api_version.split_once('/').map_or("", |(g, _)| g);
    Some((group.to_string(), kind.to_string()))
}

/// The group and kind a CRD manifest defines.
fn defined_by(crd: &Value) -> Option<(String, String)> {
    let group = crd.pointer("/spec/group").and_then(Value::as_str)?;
    let kind = crd.pointer("/spec/names/kind").and_then(Value::as_str)?;
    Some((group.to_string(), kind.to_string()))
}

/// The kinds whose CRD this deploy creates or changes, by the dry run's
/// answers. A custom resource of such a kind was checked against the CRD as
/// it is now, so a refusal of it may not happen on the deploy.
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

/// The custom resource kinds a build brings: the group and kind of each CRD
/// it contains, and the API groups of the CRDs its import markers say
/// something it installs creates (an operator that writes its own CRDs).
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

    /// Whether the kind `manifest` is of is one the build brings.
    fn brings(&self, manifest: Option<&Value>) -> bool {
        manifest
            .and_then(crd_key)
            .is_some_and(|key| self.groups.contains(&key.0) || self.kinds.contains(&key))
    }
}

/// Every resource that leaves the build, with what the deploy does to it.
fn prune_entries(
    p: &Prepared,
    args: &PlanArgs,
    answers: &HashMap<ResourceId, PruneAnswer>,
) -> Vec<PruneEntry> {
    let policy = deploy::prune_policy_for(args);
    let mut entries: Vec<PruneEntry> = p
        .orphan_rids
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
    entries.extend(p.shared_orphans.iter().map(|s| PruneEntry {
        resource: s.rid.display_id(),
        fate: PruneFate::KeptShared,
        detail: Some(s.describe()),
    }));
    entries.sort_by(|a, b| a.resource.cmp(&b.resource));
    entries
}

fn print_migrations(doc: &Plan, args: &PlanArgs) {
    let pairs = doc.migrations.items();
    if pairs.is_empty() {
        return;
    }
    println!(
        "{}",
        output::bold(&format!("Stateful migrations detected ({}):", pairs.len()))
    );
    for m in pairs {
        println!("  {} {}: {}", output::yellow("~"), m.slot, m.reason);
        println!("      source: {}", m.source);
        println!("      target: {}", m.target);
    }
    println!();
    if args.accept_migrations {
        println!(
            "{}",
            output::yellow(
                "--accept-migrations set: the deploy continues. Kix will not copy data."
            )
        );
    } else {
        println!(
            "{}",
            output::yellow(
                "The deploy stops on these. Migrate the data, then deploy with --accept-migrations."
            )
        );
    }
}

/// The text plan: the package list, the summary, and every section of
/// `doc` that found something. `verbose` lists each resource and field.
pub(crate) fn print_text(p: &Prepared, doc: &Plan, args: &PlanArgs, verbose: bool) {
    plan::print_package_plan(&p.pkg_diff, verbose);
    plan::print_plan_summary(&p.pkg_diff);

    // Jobs under the rerun rule that changed: the engine deletes and
    // recreates them, so the preview says so.
    let reruns: Vec<String> = p
        .plan
        .nodes
        .iter()
        .filter(|n| matches!(n.kind, TransitionKind::Recreate))
        .map(|n| match &n.id {
            NodeId::Resource(rid) => rid.to_string(),
            NodeId::Synthetic(s) => s.clone(),
        })
        .collect();
    if !reruns.is_empty() {
        println!(
            "  {} {} under the rerun rule (deleted first when live): {}",
            output::yellow("↻"),
            reruns.len(),
            reruns.join(", "),
        );
    }

    let fate = if args.prune_mode == Some(PruneMode::No) {
        "kept (--prune-mode=no)".to_string()
    } else if deploy::prune_flag_requested(args) && p.pre_client.is_none() {
        // `--current-activation` has not contacted the cluster, so it
        // cannot yet tell which orphans another Kix cluster deploys.
        "will be deleted, except any another Kix cluster still deploys; \
         checked once the deploy connects"
            .to_string()
    } else if deploy::prune_flag_requested(args) {
        "will be deleted".to_string()
    } else {
        format!("kept; {}", deploy::KEPT_ORPHANS_HINT)
    };
    // Shared orphans are listed with the prune section of `render::render_text`.
    print!("{}", deploy::render_plan_orphans(&p.orphan_rids, &fate));

    // Where the extra work in this plan came from. Without this the reader
    // sees a deploy of an unchanged config proposing changes, and has no way
    // to tell why.
    if !p.failed_baseline.is_empty() {
        let names: Vec<&str> = p
            .failed_baseline
            .consumed
            .iter()
            .map(String::as_str)
            .collect();
        println!(
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

    print!("{}", render::render_text(doc));
}

fn markdown(p: &Prepared, doc: &Plan) -> String {
    let mut out =
        plan::render_package_diff_markdown(&p.pkg_diff).replacen("### kix diff", "### kix plan", 1);
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
            })),
        }
    }

    /// Only a CRD the dry run would change marks its kind; one that holds
    /// live already does not.
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

    /// A build CRD covers its own group and kind, not the same kind name in
    /// another group.
    #[test]
    fn build_crds_match_group_and_kind() {
        let crds = BuildCrds::of(&[crd("example.com", "Widget", "v1")]);
        let widget = |api: &str| json!({"apiVersion": api, "kind": "Widget"});
        assert!(crds.brings(Some(&widget("example.com/v1"))));
        assert!(!crds.brings(Some(&widget("other.io/v1"))));
    }
}
