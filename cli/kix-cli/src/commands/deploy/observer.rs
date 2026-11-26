//! Render interactive deploy events, prune headers, migration warnings, and summary lines.

use crate::output;
use kix::cluster::apply::ApplyAction;
use kix::cluster::stream::{
    CancelReason, DeployEvent, DeployObserver, DeployResult, HALTED_ON_FAILURE, NodeDetail, NodeId,
    TransitionKind, Verdict,
};
use kix::manifest::types::ResourceId;

/// Line-oriented observer for interactive DAG-streaming deploys.
///
/// Emits one line per terminal verdict or phase boundary, and writes readiness
/// heartbeats to stderr under `-v`.
pub(crate) struct StreamCliObserver {
    pub(crate) verbose: bool,
    /// The Kix cluster being deployed, named in the command that deletes
    /// kept orphans.
    pub(crate) cluster: String,
}

impl DeployObserver for StreamCliObserver {
    fn on_event(&self, event: &DeployEvent) {
        match event {
            DeployEvent::PlanComputed { nodes, .. } => {
                crate::say!("{} {} nodes", output::dim("plan:"), nodes.len(),);
            }
            DeployEvent::NodeStateChanged {
                node,
                kind,
                verdict,
                detail,
            } => self.render_node_state(node, *kind, verdict, detail.as_ref()),
            DeployEvent::CrdRediscovery => {
                if self.verbose {
                    eprintln!("{} re-running API discovery", output::dim("crd:"));
                }
            }
            DeployEvent::PruneStart {
                resources,
                kept,
                delete,
                ..
            } => print!(
                "{}",
                render_prune_start(resources, kept, *delete, &self.cluster)
            ),
            DeployEvent::PruneKept { reason, .. } => {
                println!("  {} prune: {reason}", output::yellow("="));
            }
            DeployEvent::Finalized {
                activation,
                previous,
            } => {
                if let Some(prev) = previous {
                    crate::say!("  {} activation '{}' → Superseded", output::dim("•"), prev);
                }
                crate::say!(
                    "  {} activation '{}' → Active",
                    output::green("•"),
                    activation,
                );
            }
            // The failed node's line already carries a halting failure.
            DeployEvent::Stopped { reason } if !reason.starts_with(HALTED_ON_FAILURE) => {
                eprintln!("\n{} {}", output::red("✗"), output::red(reason));
            }
            DeployEvent::Stopped { .. } => {}
            DeployEvent::Stalled {
                idle,
                in_flight,
                aborting,
            } => {
                let line = kix::cluster::watchdog::describe(*idle, in_flight);
                if *aborting {
                    eprintln!("{} {line}; giving up", output::red("stalled:"));
                } else {
                    eprintln!("{} {line}", output::yellow("stalled:"));
                }
            }
            DeployEvent::Waiting {
                node,
                phase,
                since,
                status,
                budget,
                holds,
                holds_total,
            } => {
                let line = kix::cluster::watchdog::describe_wait(
                    node,
                    *phase,
                    *since,
                    status.as_deref(),
                    *budget,
                    holds,
                    *holds_total,
                );
                crate::say!("  {} {}", output::dim("…"), output::dim(&line));
            }
            DeployEvent::BestEffortFailed { what, message } => {
                eprintln!("{} {what} failed: {message}", output::yellow("warn:"),);
            }
            DeployEvent::FieldsNotKept { resource, fields } => {
                eprintln!(
                    "{} Kubernetes did not keep fields Kix applied to {resource}:",
                    output::yellow("warn:"),
                );
                for f in fields {
                    eprintln!("    {}", kix::cluster::kept::describe_field(f));
                }
            }
        }
    }
}

impl StreamCliObserver {
    fn render_node_state(
        &self,
        node: &NodeId,
        kind: TransitionKind,
        verdict: &Verdict,
        detail: Option<&NodeDetail>,
    ) {
        let label = node.to_string();
        let tag = kind
            .tag()
            .map(|t| format!("{} ", output::dim(t)))
            .unwrap_or_default();
        if kind == TransitionKind::Delete
            && let Some(line) = super::super::deploy_log::delete_line(verdict, detail)
        {
            let symbol = if matches!(verdict, Verdict::Ready) {
                output::green("✔")
            } else {
                output::dim("…")
            };
            println!("  {symbol} {label} {}", output::dim(&line));
            return;
        }
        match verdict {
            Verdict::Pending => {}
            Verdict::Running => match detail {
                Some(NodeDetail::Applied(action))
                    if (!output::quiet() || !matches!(action, ApplyAction::Unchanged)) =>
                {
                    let (symbol, lbl) = apply_symbol(action);
                    println!("  {} {}{} {}", symbol, tag, label, output::dim(lbl));
                }
                Some(NodeDetail::SecretHydrated { keys }) => {
                    crate::say!(
                        "  {} {} hydrated ({} keys from SOPS)",
                        output::green("🔓"),
                        label,
                        keys,
                    );
                }
                Some(NodeDetail::ReadinessProgress(_)) => {}
                _ => {}
            },
            Verdict::Ready => match detail {
                Some(NodeDetail::Applied(action)) => {
                    // Skip nodes reach Ready via `Applied(Unchanged)`; print a
                    // single dim line under `-v` instead of a green ready line.
                    if matches!(kind, TransitionKind::Skip) {
                        if self.verbose {
                            let (_, lbl) = apply_symbol(action);
                            println!(
                                "  {} {}{} {}",
                                output::dim("="),
                                tag,
                                label,
                                output::dim(lbl)
                            );
                        }
                    } else {
                        println!(
                            "  {} {} {}",
                            output::green("✔"),
                            label,
                            output::dim("ready")
                        );
                    }
                }
                Some(NodeDetail::RecreatedInPlace { reason }) => {
                    println!(
                        "  {} {} {} {}",
                        output::yellow("↻"),
                        label,
                        output::yellow("recreated (immutable-field conflict)"),
                        output::dim(reason),
                    );
                }
                Some(NodeDetail::Rerun { reason }) => {
                    println!(
                        "  {} {} {}",
                        output::yellow("↻"),
                        label,
                        output::yellow(&format!("ran again ({reason})")),
                    );
                }
                Some(NodeDetail::PendingRestart { message, .. }) => {
                    println!(
                        "  {} {} {} {}",
                        output::yellow("✔"),
                        label,
                        output::yellow("ready, restart pending:"),
                        output::dim(message),
                    );
                }
                _ => {
                    println!(
                        "  {} {} {}",
                        output::green("✔"),
                        label,
                        output::dim("ready")
                    );
                }
            },
            Verdict::Failed { message } => {
                let detail_tail = match detail {
                    Some(NodeDetail::ReadinessFailed { missing_keys, .. })
                        if !missing_keys.is_empty() =>
                    {
                        format!(
                            "\n    {} missing key(s): {}",
                            output::red("↳"),
                            missing_keys.join(", "),
                        )
                    }
                    Some(NodeDetail::ReadinessTimeout { elapsed, .. }) => {
                        format!(" {}", output::dim(&format!("({}s)", elapsed.as_secs())))
                    }
                    _ => String::new(),
                };
                eprintln!(
                    "  {} {} {}{}",
                    output::red("⚠"),
                    label,
                    output::red(message),
                    detail_tail,
                );
                // Print container output captured from a failed readiness probe
                // so the failure reason is visible without `kubectl logs`.
                if let Some(NodeDetail::ReadinessFailed { output, .. }) = detail {
                    for line in output {
                        eprintln!("      {}", output::dim(line));
                    }
                }
            }
            Verdict::Cancelled { because } => {
                if self.verbose {
                    println!(
                        "  {} {} {}",
                        output::dim("⊘"),
                        label,
                        output::dim(&held_back(because)),
                    );
                }
            }
            Verdict::AwaitingInput { prompt } => {
                println!(
                    "  {} {} {}",
                    output::yellow("⏯"),
                    label,
                    output::yellow(prompt)
                );
            }
            Verdict::DriftDetected { message, .. } => {
                println!(
                    "  {} {} {}",
                    output::yellow("↻"),
                    label,
                    output::yellow(message),
                );
            }
        }
    }
}

/// Describe a node held back by `because`.
pub(crate) fn held_back(because: &CancelReason) -> String {
    match because {
        CancelReason::PredecessorFailed(rid) => format!("not started ({rid} failed)"),
        CancelReason::External => "interrupted".to_string(),
    }
}

fn apply_symbol(action: &ApplyAction) -> (std::borrow::Cow<'static, str>, &'static str) {
    // Keep apply-phase glyphs muted so terminal `✔ ready` lines stand out in
    // green.
    match action {
        ApplyAction::Created => (std::borrow::Cow::Borrowed("+"), "created"),
        ApplyAction::Configured => (output::yellow("~"), "configured"),
        ApplyAction::Unchanged => (output::dim("="), "unchanged"),
        ApplyAction::Skipped => (output::dim("-"), "skipped"),
    }
}

/// Format the prune header and resource list, separating deleted or reported
/// orphans from protected orphans.
pub(super) fn render_prune_start(
    resources: &[ResourceId],
    kept: &[ResourceId],
    delete: bool,
    cluster: &str,
) -> String {
    use std::fmt::Write;
    let mut out = String::new();
    if !resources.is_empty() {
        let _ = writeln!(out);
        if delete {
            let _ = writeln!(
                out,
                "{} deleting {} object(s) that left the build...",
                output::bold("prune:"),
                resources.len(),
            );
        } else {
            let _ = writeln!(
                out,
                "{} {} object(s) left the build, {}:",
                output::bold("prune:"),
                resources.len(),
                crate::plan::kept_orphans_fate(cluster),
            );
        }
        for rid in resources {
            let _ = writeln!(out, "  {} {}", output::dim("-"), rid.display_id());
        }
    }
    if !kept.is_empty() {
        let _ = writeln!(out);
        let _ = writeln!(
            out,
            "{} {} object(s) left the build and stay on the cluster (never deleted automatically; delete with `kubectl` if intended):",
            output::bold("prune:"),
            kept.len(),
        );
        for rid in kept {
            let _ = writeln!(out, "  {} {}", output::yellow("!"), rid.display_id());
        }
    }
    out
}

/// Format the counts of a run: created, configured, unchanged, and failed,
/// then the objects that did not finish when `not_finished` is set, then the
/// pruned ones when any were.
pub(crate) fn counts(r: &DeployResult, not_finished: bool) -> String {
    counts_labelled(r, not_finished.then_some("not finished"))
}

/// Format the counts as [`counts`] does, naming the held-back objects with
/// `held_back` when it is set.
fn counts_labelled(r: &DeployResult, held_back: Option<&str>) -> String {
    let failed_str = r.failed.to_string();
    let mut text = format!(
        "{} created, {} configured, {} unchanged, {} failed",
        output::green(&r.created.to_string()),
        output::yellow(&r.configured.to_string()),
        output::dim(&r.unchanged.to_string()),
        if r.failed > 0 {
            output::red(&failed_str)
        } else {
            output::dim(&failed_str)
        },
    );
    text.push_str(&applied_then_not_ready(r));
    if let Some(label) = held_back {
        text.push_str(&format!(
            ", {} {label}",
            output::dim(&r.cancelled.to_string())
        ));
    }
    if r.pruned > 0 {
        text.push_str(&format!(", {} pruned", output::red(&r.pruned.to_string())));
    }
    text
}

/// Return how many failed objects this run wrote before they failed
/// readiness, as ` (N applied, then not ready)`, or nothing when none did.
/// They are on the cluster with the new spec, though the counts of created
/// and configured objects leave them out.
fn applied_then_not_ready(r: &DeployResult) -> String {
    match r.failed_after_apply {
        0 => String::new(),
        n => format!(" ({n} applied but not ready)"),
    }
}

fn failed_cluster_state(r: &DeployResult) -> String {
    match r.failed_after_apply {
        0 => String::new(),
        1 => " (1 applied but not ready; its new manifest is on the cluster)".to_string(),
        n => format!(" ({n} applied but not ready; their new manifests are on the cluster)"),
    }
}

/// Format the one-line summary of a deploy or dry run that succeeded, or of
/// one that stopped for a reason [`closing`] does not describe.
pub(super) fn summary_line(r: &DeployResult, command: super::Command, succeeded: bool) -> String {
    let run = command.noun();
    let ending = if succeeded {
        "complete"
    } else if r.failed > 0 {
        "failed"
    } else {
        "stopped"
    };
    format!("{run} {ending}: {}", counts(r, !succeeded))
}

/// The record the cluster treats as current, as far as this run knows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Previous {
    /// The Active record before this run.
    Active(String),
    /// The cluster had no Active record: this is its first deploy.
    FirstDeploy,
    /// This run did not read the cluster's records (`--offline`).
    Unknown,
}

/// What the text that closes a failed deploy needs besides the counts.
pub(crate) struct Closing<'a> {
    pub command: super::Command,
    pub cluster: &'a str,
    /// This run's deployment record, when the build has one.
    pub record: Option<&'a str>,
    pub previous: Previous,
    /// Why the run was interrupted, when it was.
    pub interrupted: Option<&'a str>,
    /// Whether this run's record became current.
    pub current: bool,
    /// Whether `--on-error continue` was set.
    pub on_error_continue: bool,
    /// The instances `--only` named, empty for a deploy of the whole
    /// build. The command to run again names them too.
    pub only: &'a [String],
}

/// What the text that closes a deploy with `--only` needs besides the
/// counts.
pub(crate) struct PartialClosing<'a> {
    pub cluster: &'a str,
    /// This run's deployment record, when the build has one.
    pub record: Option<&'a str>,
    pub previous: &'a Previous,
    /// The instances `--only` named.
    pub only: &'a [String],
    /// The instances the named ones need, which the run applied in full too.
    pub needed: &'a [String],
    /// What the run left for a later deploy of the whole build.
    pub left_alone: kix::plan::document::LeftAlone,
}

/// Format the text that closes a deploy with `--only` that applied every
/// object it selected: the counts, what it applied, that the cluster's
/// current deploy record is unchanged, what is left, and how to apply it.
pub(super) fn partial_closing(r: &DeployResult, c: &PartialClosing<'_>) -> String {
    use std::fmt::Write;
    let cluster = c.cluster;
    let mut out = String::new();
    let _ = writeln!(
        out,
        "Deploy of part of '{cluster}' complete: {}",
        counts(r, false)
    );
    let _ = writeln!(out);
    let _ = writeln!(out, "  Cluster state:");
    let list = |names: &[String]| names.join(", ");
    let _ = writeln!(out, "    - Applied in full, as named: {}.", list(c.only));
    if !c.needed.is_empty() {
        let _ = writeln!(
            out,
            "    - Applied in full, because the named instance(s) need them: {}.",
            list(c.needed)
        );
    }
    let _ = writeln!(
        out,
        "    - Applied the objects outside any instance that they depend on."
    );
    let current = matches!(
        (c.record, c.previous),
        (Some(record), Previous::Active(previous)) if record == previous
    );
    match (c.record, c.previous) {
        (Some(record), Previous::Active(_)) if current => {
            let _ = writeln!(
                out,
                "    - Deployment record {record} remains the Active deployment record, because this build is the one the cluster runs."
            );
        }
        (Some(record), Previous::Active(previous)) => {
            let _ = writeln!(
                out,
                "    - Deployment record {record} is marked partly deployed, and {previous} remains the Active deployment record."
            );
        }
        (Some(record), _) => {
            let _ = writeln!(
                out,
                "    - Deployment record {record} is marked partly deployed, and the Active deployment record is unchanged."
            );
        }
        (None, _) => {}
    }
    let left = c.left_alone;
    if left.total() > 0 {
        let _ = writeln!(
            out,
            "    - {} object(s) of this build that differ from the current deploy record were outside this deploy: {} to write and {} that left the build. An earlier deploy with `--only` may already have applied some of them.",
            left.total(),
            left.writes,
            left.orphans
        );
    }
    let _ = writeln!(out);
    let _ = writeln!(out, "  Next:");
    if current {
        let _ = write!(out, "    Nothing else of this build waits.");
    } else {
        let _ = write!(
            out,
            "    Deploy another instance with `kix deploy {cluster} --only <namespace>/<instance>`, or apply the rest of the build with `kix deploy {cluster}`."
        );
    }
    out
}

/// Format the text that closes a deploy that did not succeed: the counts,
/// the failed resources, what state the cluster is in, and what to do next.
pub(super) fn closing(r: &DeployResult, c: &Closing<'_>) -> String {
    use std::fmt::Write;
    let cluster = c.cluster;
    let noun = c.command.noun();
    let again = std::iter::once(format!("{} {cluster}", c.command.invocation()))
        .chain(c.only.iter().map(|n| format!("--only {n}")))
        .collect::<Vec<_>>()
        .join(" ");
    let mut out = String::new();
    let failures = |out: &mut String| {
        if r.failures.is_empty() {
            return;
        }
        let _ = writeln!(out);
        let _ = writeln!(out, "  Failed resources ({}):", r.failures.len());
        for f in &r.failures {
            let first = f.message.lines().next().unwrap_or_default();
            let _ = writeln!(out, "    - {}: {first}", f.node);
        }
    };
    if c.current {
        // The record became current although objects failed: under
        // `--on-error continue`, or when only a prune delete failed.
        if c.on_error_continue {
            let _ = writeln!(
                out,
                "{noun} of '{cluster}' finished with {} failure(s) (`--on-error continue`): {}",
                r.failed,
                counts(r, false)
            );
        } else {
            let _ = writeln!(
                out,
                "{noun} of '{cluster}' finished with {} failure(s): {}",
                r.failed,
                counts(r, false)
            );
        }
        failures(&mut out);
        let _ = writeln!(out);
        let _ = writeln!(out, "  Cluster state:");
        let _ = writeln!(
            out,
            "    - {} created and {} configured object(s) are live on the cluster.",
            r.created, r.configured
        );
        if let Some(record) = c.record {
            if c.on_error_continue {
                let _ = writeln!(
                    out,
                    "    - Because `--on-error continue` was set and no objects were held back, deployment record {record} is now Active."
                );
            } else {
                let _ = writeln!(out, "    - Deployment record {record} is now Active.");
            }
        }
        let _ = writeln!(out);
        let _ = writeln!(out, "  Next:");
        let _ = write!(
            out,
            "    Fix the failed resource(s) above and run `{again}` again."
        );
        return out;
    }
    // A run that applies the build the Active record already holds, such as
    // a reconcile of an unchanged build, reuses that record and leaves it
    // Active.
    let reused = matches!(
        (c.record, &c.previous),
        (Some(record), Previous::Active(previous)) if record == previous
    );
    let record_line = match (c.record, &c.previous) {
        (Some(record), Previous::Active(_)) if reused => Some(format!(
            "Deployment record {record} remains the Active deployment record, because this run applied the build it already holds."
        )),
        (Some(record), Previous::Active(previous)) => Some(format!(
            "Deployment record {record} is marked Failed, and {previous} remains the Active deployment record."
        )),
        (Some(record), Previous::FirstDeploy) => Some(format!(
            "Deployment record {record} is marked Failed, and the cluster has no Active deployment record yet."
        )),
        (Some(record), Previous::Unknown) => {
            Some(format!("Deployment record {record} is marked Failed."))
        }
        (None, Previous::Active(previous)) => {
            Some(format!("{previous} remains the Active deployment record."))
        }
        (None, Previous::FirstDeploy) => {
            Some("The cluster has no Active deployment record yet.".to_string())
        }
        (None, Previous::Unknown) => None,
    };
    match c.interrupted {
        Some(reason) => {
            let _ = writeln!(
                out,
                "{noun} of '{cluster}' stopped ({reason}): {}",
                counts(r, true)
            );
            let _ = writeln!(out);
            let _ = writeln!(out, "  Cluster state:");
            let _ = writeln!(
                out,
                "    - {} created and {} configured object(s) finished before the run stopped.",
                r.created, r.configured
            );
            let _ = writeln!(
                out,
                "    - {} object(s) did not finish (some may already have been sent to the cluster, while the rest were not started).",
                r.cancelled
            );
            if let Some(line) = record_line {
                let _ = writeln!(out, "    - {line}");
            }
            if let Some(record) = c.record {
                let _ = writeln!(
                    out,
                    "    - {}",
                    next_compare(cluster, record, reused, "this run")
                );
            }
            let _ = writeln!(out);
            let _ = writeln!(out, "  Next:");
            let _ = write!(out, "    Run `{again}` again to finish applying the build.");
        }
        None => {
            let _ = writeln!(
                out,
                "{noun} of '{cluster}' failed: {}",
                counts_labelled(r, Some("not started"))
            );
            failures(&mut out);
            let _ = writeln!(out);
            let _ = writeln!(out, "  Cluster state:");
            let _ = writeln!(
                out,
                "    - {} created and {} configured object(s) from this run are ready on the cluster. {} failed{}, and {} were never sent to the cluster.",
                r.created,
                r.configured,
                r.failed,
                failed_cluster_state(r),
                r.cancelled
            );
            if let Some(line) = record_line {
                let _ = writeln!(out, "    - {line}");
            }
            if let Some(record) = c.record {
                let _ = writeln!(
                    out,
                    "    - {}",
                    next_compare(cluster, record, reused, "this failed run")
                );
            }
            let _ = writeln!(out);
            let _ = writeln!(out, "  Next:");
            let _ = write!(
                out,
                "    Fix the failed resource(s) above and run `{again}` again."
            );
        }
    }
    out
}

/// Say what the next deploy compares the build against after a run that did
/// not finish.
fn next_compare(cluster: &str, record: &str, reused: bool, run: &str) -> String {
    if reused {
        format!(
            "The next `kix deploy {cluster}` on a machine with this build will compare against deployment record {record}, which holds the build {run} applied."
        )
    } else {
        format!(
            "The next `kix deploy {cluster}` on a machine with this build will compare against what {run} applied."
        )
    }
}

pub(super) fn print_warnings(lines: &[String]) {
    if lines.is_empty() {
        return;
    }
    crate::say!();
    for line in lines {
        crate::say!("{line}");
    }
}
