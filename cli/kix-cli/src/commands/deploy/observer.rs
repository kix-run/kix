//! Render interactive deploy events, prune headers, migration warnings, and summary lines.

use crate::output;
use crate::plan;
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
            } => print!("{}", render_prune_start(resources, kept, *delete)),
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
                Some(NodeDetail::PendingRestart { stale, message }) => {
                    println!(
                        "  {} {} {} {}",
                        output::yellow("✔"),
                        label,
                        output::yellow(&format!(
                            "ready, {stale} pods pending manual restart (OnDelete):"
                        )),
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
) -> String {
    use std::fmt::Write;
    let mut out = String::new();
    if !resources.is_empty() {
        let _ = writeln!(out);
        if delete {
            let _ = writeln!(
                out,
                "{} deleting {} orphaned resources...",
                output::bold("prune:"),
                resources.len(),
            );
        } else {
            let _ = writeln!(
                out,
                "{} {} orphaned resources kept (warn-only; {})",
                output::bold("prune:"),
                resources.len(),
                plan::KEPT_ORPHANS_HINT,
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
            "{} {} orphaned resources are never deleted automatically",
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

/// Format the one-line summary of a deploy or dry run that succeeded, or of
/// one that stopped for a reason [`closing`] does not describe.
pub(super) fn summary_line(r: &DeployResult, dry_run: bool, succeeded: bool) -> String {
    let run = if dry_run { "Dry run" } else { "Deploy" };
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
    /// This run did not read the cluster's records (`--current-activation`).
    Unknown,
}

/// What the text that closes a failed deploy needs besides the counts.
pub(crate) struct Closing<'a> {
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
}

/// Format the text that closes a deploy that did not succeed: the counts,
/// the failed resources, what state the cluster is in, and what to do next.
pub(super) fn closing(r: &DeployResult, c: &Closing<'_>) -> String {
    use std::fmt::Write;
    let cluster = c.cluster;
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
                "Deploy of '{cluster}' finished with {} failure(s) (`--on-error continue`): {}",
                r.failed,
                counts(r, false)
            );
        } else {
            let _ = writeln!(
                out,
                "Deploy of '{cluster}' finished with {} failure(s): {}",
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
            "    Fix the failed resource(s) above and run `kix deploy {cluster}` again."
        );
        return out;
    }
    let record_line = match (c.record, &c.previous) {
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
                "Deploy of '{cluster}' stopped ({reason}): {}",
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
            if c.record.is_some() {
                let _ = writeln!(
                    out,
                    "    - The next `kix deploy {cluster}` on a machine with this build will compare against what this run applied."
                );
            }
            let _ = writeln!(out);
            let _ = writeln!(out, "  Next:");
            let _ = write!(
                out,
                "    Run `kix deploy {cluster}` again to finish applying the build."
            );
        }
        None => {
            let _ = writeln!(
                out,
                "Deploy of '{cluster}' failed: {}",
                counts_labelled(r, Some("not started"))
            );
            failures(&mut out);
            let _ = writeln!(out);
            let _ = writeln!(out, "  Cluster state:");
            let _ = writeln!(
                out,
                "    - {} created and {} configured object(s) from this run finished and are ready on the cluster, {} failed (during apply or after being applied), and {} were never sent to the cluster.",
                r.created, r.configured, r.failed, r.cancelled
            );
            if let Some(line) = record_line {
                let _ = writeln!(out, "    - {line}");
            }
            if c.record.is_some() {
                let _ = writeln!(
                    out,
                    "    - The next `kix deploy {cluster}` on a machine with this build will compare against what this failed run applied."
                );
            }
            let _ = writeln!(out);
            let _ = writeln!(out, "  Next:");
            let _ = write!(
                out,
                "    Fix the failed resource(s) above and run `kix deploy {cluster}` again."
            );
        }
    }
    out
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
