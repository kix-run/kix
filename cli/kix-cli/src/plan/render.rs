//! Text and Markdown for the sections of a [`Plan`] beyond its packages.
//!
//! The package list is rendered by `render_package_plan` and
//! `render_package_diff_markdown`; these add what the write path found
//! (conflicts, refusals, prune fates, objects not checked) and what the
//! three-way comparison found (drift), each saying when it did not look.

use std::fmt::Write;

use crate::output;

use super::document::{
    AdmissionRefusal, Checked, MadeBy, NotCheckedReason, Plan, PruneFate, RefusalReason,
    UncheckedReason,
};
use super::origin::ChangeLabel;

/// The tag after a field change in the text plan. Intent is the expected
/// case and carries no tag.
pub fn label_tag(labels: &[ChangeLabel]) -> String {
    if labels.contains(&ChangeLabel::RevertsDrift) {
        output::yellow("(reverts drift)").into_owned()
    } else if labels.contains(&ChangeLabel::DriftKept) {
        output::dim("(drift; deploy leaves this object alone)").into_owned()
    } else {
        String::new()
    }
}

/// Everything the text plan prints below the package list.
pub fn render_text(plan: &Plan) -> String {
    let mut out = String::new();
    write_stops(&mut out, plan);
    write_drift(&mut out, plan);
    write_prune(&mut out, plan);
    write_not_checked(&mut out, plan);
    out
}

fn write_stops(out: &mut String, plan: &Plan) {
    let conflicts = plan.conflicts.items();
    let refusals = plan.admission.items();
    let prune_refused: Vec<_> = plan
        .prune
        .items()
        .iter()
        .filter(|p| p.fate == PruneFate::DeleteRefused)
        .collect();
    let count = conflicts.len() + refusals.len() + prune_refused.len();
    if count == 0 {
        return;
    }
    let _ = writeln!(out);
    let _ = writeln!(
        out,
        "{}",
        output::red(&format!(
            "The deploy would stop on {count} write{}:",
            if count == 1 { "" } else { "s" }
        ))
    );
    for c in conflicts {
        let _ = writeln!(
            out,
            "  {} {} {}",
            output::red("✗"),
            c.resource,
            output::red("field ownership conflict"),
        );
        for o in &c.owners {
            let _ = writeln!(out, "      {} owns {}", o.manager, o.fields.join(", "));
        }
        let _ = writeln!(
            out,
            "      {}",
            output::dim(
                "--force-conflicts takes the fields; `ownership.cede` on the resource leaves them to the other manager"
            )
        );
    }
    for r in refusals {
        let _ = writeln!(
            out,
            "  {} {} {}",
            output::red("✗"),
            r.resource,
            output::red(&refusal_title(r)),
        );
        let _ = writeln!(out, "      {}", output::dim(&r.message));
    }
    for p in prune_refused {
        let _ = writeln!(
            out,
            "  {} {} {}",
            output::red("✗"),
            p.resource,
            output::red("prune delete refused"),
        );
        if let Some(detail) = &p.detail {
            let _ = writeln!(out, "      {}", output::dim(detail));
        }
    }
}

fn refusal_title(r: &AdmissionRefusal) -> String {
    match (r.reason, &r.webhook) {
        (RefusalReason::WebhookDenied, Some(w)) => format!("denied by admission webhook {w}"),
        (RefusalReason::WebhookDenied, None) => "denied by an admission webhook".into(),
        (RefusalReason::PolicyDenied, Some(p)) => format!("denied by admission policy {p}"),
        (RefusalReason::PolicyDenied, None) => "denied by an admission policy".into(),
        (RefusalReason::Invalid, _) => "invalid".into(),
        (RefusalReason::ImmutableField, _) => {
            "changes a field that cannot be modified; delete and recreate it".into()
        }
        (RefusalReason::Forbidden, _) => "forbidden".into(),
        (RefusalReason::NamespaceMissing, _) => {
            "its namespace does not exist and the build does not create it".into()
        }
        (RefusalReason::UnknownKind, _) => {
            "the cluster does not serve its kind and the build has no CRD for it".into()
        }
        (RefusalReason::Decryption, _) => "could not decrypt the SOPS Secret".into(),
        (RefusalReason::Other, _) => "refused".into(),
    }
}

fn write_drift(out: &mut String, plan: &Plan) {
    match &plan.drift {
        Checked::Checked { items } if !items.is_empty() => {
            let _ = writeln!(out);
            let _ = writeln!(
                out,
                "{}",
                output::yellow(&format!(
                    "Drift: {} field{} differ{} live from the deployed build:",
                    items.len(),
                    if items.len() == 1 { "" } else { "s" },
                    if items.len() == 1 { "s" } else { "" },
                ))
            );
            for d in items {
                let by = if d.managers.is_empty() {
                    String::new()
                } else {
                    format!(", set by {}", d.managers.join(", "))
                };
                let fate = if d.reverted {
                    output::yellow("the deploy puts the deployed value back")
                } else {
                    output::dim("the deploy leaves this object alone; --reconcile reverts it")
                };
                let _ = writeln!(
                    out,
                    "  {} {} {}: {} live, {} deployed{by}",
                    output::yellow("↺"),
                    d.resource,
                    d.path.trim_start_matches("$."),
                    compact(d.live.as_ref()),
                    compact(d.deployed.as_ref()),
                );
                let _ = writeln!(out, "      {fate}");
            }
        }
        Checked::NotChecked {
            reason: NotCheckedReason::DeployedBuildUnavailable,
        } => {
            let _ = writeln!(out);
            let _ = writeln!(
                out,
                "{}",
                output::dim(
                    "Drift not checked: the deployed build is not on this machine, so changes are not labelled as the commit's or as drift."
                )
            );
        }
        _ => {}
    }
}

/// A value short enough for one drift line: its first line, cut at 60
/// characters, with the full size when anything was cut.
fn compact(v: Option<&serde_json::Value>) -> String {
    const WIDTH: usize = 60;
    let Some(v) = v else {
        return "(absent)".into();
    };
    let full = match v {
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    let first = full.lines().next().unwrap_or_default();
    let cut = if first.len() > WIDTH {
        &first[..first.floor_char_boundary(WIDTH)]
    } else {
        first
    };
    let shown = if v.is_string() {
        format!("{cut:?}")
    } else {
        cut.to_string()
    };
    if cut.len() == full.len() {
        shown
    } else {
        format!("{shown}… ({} bytes)", full.len())
    }
}

fn write_prune(out: &mut String, plan: &Plan) {
    let items = plan.prune.items();
    let shared: Vec<_> = items
        .iter()
        .filter(|p| matches!(p.fate, PruneFate::KeptShared | PruneFate::KeptChanged))
        .collect();
    if shared.is_empty() {
        return;
    }
    let _ = writeln!(out);
    let _ = writeln!(
        out,
        "{} {} orphans stay, found when the prune came to delete them:",
        output::bold("Prune:"),
        shared.len()
    );
    for p in shared {
        let _ = writeln!(
            out,
            "  {} {} {}",
            output::yellow("="),
            p.resource,
            output::dim(p.detail.as_deref().unwrap_or("")),
        );
    }
}

fn write_not_checked(out: &mut String, plan: &Plan) {
    if plan.made_by == MadeBy::DryRun && !plan.not_checked.is_empty() {
        let _ = writeln!(out);
        let _ = writeln!(
            out,
            "{}",
            output::dim(&format!(
                "Not checked by the dry run ({}); their changes come from comparing builds:",
                plan.not_checked.len()
            ))
        );
        let mut groups: Vec<(UncheckedReason, Vec<&str>)> = Vec::new();
        for o in &plan.not_checked {
            match groups.iter_mut().find(|(r, _)| *r == o.reason) {
                Some((_, names)) => names.push(&o.resource),
                None => groups.push((o.reason, vec![&o.resource])),
            }
        }
        for (reason, names) in groups {
            let why = match reason {
                UncheckedReason::CrdCreatedByThisDeploy => "its CRD is created by this deploy",
                UncheckedReason::NamespaceCreatedByThisDeploy => {
                    "its namespace is created by this deploy"
                }
                UncheckedReason::WebhookNoDryRun => {
                    "an admission webhook it calls does not support dry run"
                }
                UncheckedReason::DependencyNotChecked => "the dry run did not reach it",
            };
            let _ = writeln!(out, "  {} {} {}:", output::dim("?"), names.len(), why);
            for name in names.iter().take(5) {
                let _ = writeln!(out, "      {}", output::dim(name));
            }
            if names.len() > 5 {
                let _ = writeln!(
                    out,
                    "      {}",
                    output::dim(&format!(
                        "and {} more (-o json lists them)",
                        names.len() - 5
                    ))
                );
            }
        }
    }
    if !plan.has_changes() {
        return;
    }
    match plan.made_by {
        MadeBy::DryRun => {
            let _ = writeln!(out);
            let _ = writeln!(
                out,
                "{}",
                output::dim(
                    "Not checked by any preview: whether Pods start, pull their images, and pass their probes."
                )
            );
        }
        MadeBy::LiveRead => {
            let _ = writeln!(out);
            let _ = writeln!(
                out,
                "{}",
                output::dim(
                    "Not checked: admission webhooks, field ownership conflicts, and what the deploy itself refuses. `kix plan` checks them with a server-side dry run."
                )
            );
        }
        MadeBy::Builds => {
            let _ = writeln!(out);
            let _ = writeln!(
                out,
                "{}",
                output::dim(
                    "Two builds compared; nothing was read from or sent to the cluster. Not checked: drift, admission webhooks, field ownership conflicts, and what the deploy itself refuses."
                )
            );
        }
    }
}

/// Everything the Markdown plan prints below the package list.
pub fn render_markdown(plan: &Plan) -> String {
    let mut out = String::new();
    let conflicts = plan.conflicts.items();
    let refusals = plan.admission.items();
    if !conflicts.is_empty() || !refusals.is_empty() {
        let _ = writeln!(out, "#### :x: The deploy would stop on these writes");
        let _ = writeln!(out);
        for c in conflicts {
            let owners: Vec<String> = c
                .owners
                .iter()
                .map(|o| format!("`{}` owns `{}`", o.manager, o.fields.join("`, `")))
                .collect();
            let _ = writeln!(
                out,
                "- `{}`: field ownership conflict, {}",
                c.resource,
                owners.join("; ")
            );
        }
        for r in refusals {
            let _ = writeln!(out, "- `{}`: {}", r.resource, refusal_title(r));
            let _ = writeln!(out, "  > {}", r.message.replace('\n', " "));
        }
        let _ = writeln!(out);
    }
    if let Checked::Checked { items } = &plan.drift
        && !items.is_empty()
    {
        let _ = writeln!(out, "#### Drift");
        let _ = writeln!(out);
        let _ = writeln!(
            out,
            "Fields where the live cluster differs from the deployed build:"
        );
        let _ = writeln!(out);
        for d in items {
            let by = if d.managers.is_empty() {
                String::new()
            } else {
                format!(", set by `{}`", d.managers.join("`, `"))
            };
            let fate = if d.reverted {
                "the deploy puts the deployed value back"
            } else {
                "the deploy leaves this object alone"
            };
            let _ = writeln!(
                out,
                "- `{}` `{}`: `{}` live, `{}` deployed{by}; {fate}",
                d.resource,
                d.path.trim_start_matches("$."),
                compact(d.live.as_ref()),
                compact(d.deployed.as_ref()),
            );
        }
        let _ = writeln!(out);
    }
    if !plan.not_checked.is_empty() {
        let _ = writeln!(
            out,
            "<details><summary>Not checked by the dry run ({})</summary>",
            plan.not_checked.len()
        );
        let _ = writeln!(out);
        for o in &plan.not_checked {
            let _ = writeln!(out, "- `{}`: {}", o.resource, o.detail);
        }
        let _ = writeln!(out);
        let _ = writeln!(out, "</details>");
        let _ = writeln!(out);
    }
    let note = match plan.made_by {
        MadeBy::DryRun => {
            "Made by a server-side dry run. Not checked: whether Pods start, pull their images, and pass their probes."
        }
        MadeBy::LiveRead => {
            "Made by a read-only comparison with the cluster. Not checked: admission, field ownership, and deploy refusals; `kix plan` checks them."
        }
        MadeBy::Builds => {
            "Made by comparing two builds, with no cluster read. Not checked: drift, admission, field ownership, and deploy refusals."
        }
    };
    let _ = writeln!(out, "> {note}");
    let _ = writeln!(out);
    out
}
