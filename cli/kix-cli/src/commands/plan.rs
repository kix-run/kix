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
use kix::manifest::lifecycle;
use kix::manifest::types::ResourceId;

use crate::cli::{OutputFormat, PlanArgs, PruneMode};
use crate::output;
use crate::plan::document::{
    AdmissionRefusal, Checked, Conflict, ConflictOwner, MadeBy, NotCheckedReason, Plan, PruneEntry,
    PruneFate, RefusalReason, UncheckedObject, UncheckedReason,
};
use crate::plan::server::Overlay;
use crate::plan::{self, render};

use super::CommandContext;
use super::deploy::{self, Prepared};

/// Exit status when the deploy would stop: a refused write, or a stateful
/// migration not accepted with `--accept-migrations`.
const EXIT_WOULD_STOP: i32 = 3;
/// Exit status when the deploy would change something.
const EXIT_CHANGES: i32 = 2;

pub fn run(args: &PlanArgs, ctx: &mut CommandContext) -> Result<()> {
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
    let doc = document(&mut p, report.as_ref(), args);

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
        // The interrupt listener holds Ctrl-C until its token is cancelled.
        // A deploy asks for confirmation next, where Ctrl-C must exit.
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
pub(crate) fn document(p: &mut Prepared, report: Option<&DryRunReport>, args: &PlanArgs) -> Plan {
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

    let mut doc = Plan::new(
        made_by,
        &p.cluster,
        &p.pkg_diff,
        &p.migration_pairs,
        NotCheckedReason::BuildsOnly,
    );
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

    for answer in answers {
        let resource = answer.rid.display_id();
        let refusal = match &answer.outcome {
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
            Refusal::UnknownKind { kind }
                if !served.is_some_and(|s| s.contains(kind))
                    && crds.brings(kind, manifests.get(&answer.rid).copied()) =>
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

/// The custom resource kinds a build brings: the kinds of the CRDs it
/// contains, and the API groups of the CRDs its import markers say
/// something it installs creates (an operator that writes its own CRDs).
struct BuildCrds {
    kinds: HashSet<String>,
    groups: HashSet<String>,
}

impl BuildCrds {
    fn of(manifests: &[Value]) -> Self {
        let kinds = manifests
            .iter()
            .filter(|m| m.get("kind").and_then(Value::as_str) == Some("CustomResourceDefinition"))
            .filter_map(|m| m.pointer("/spec/names/kind").and_then(Value::as_str))
            .map(str::to_string)
            .collect();
        let groups = manifests
            .iter()
            .filter_map(|m| readiness::import_target_from_manifest(m).ok().flatten())
            .filter(|t| t.kind == "CustomResourceDefinition")
            .filter_map(|t| t.name.split_once('.').map(|(_, group)| group.to_string()))
            .collect();
        BuildCrds { kinds, groups }
    }

    /// Whether `kind`, as `manifest` uses it, is one the build brings.
    fn brings(&self, kind: &str, manifest: Option<&Value>) -> bool {
        let group = manifest
            .and_then(|m| m.get("apiVersion"))
            .and_then(Value::as_str)
            .and_then(|av| av.split_once('/'))
            .map(|(group, _)| group);
        self.kinds.contains(kind) || group.is_some_and(|g| self.groups.contains(g))
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
    print!("{}", deploy::render_plan_orphans(&p.orphan_rids, &fate));
    super::shared_orphans::print(&p.shared_orphans);

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
