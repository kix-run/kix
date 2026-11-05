//! Text and Markdown rendering for the non-package sections of a [`Plan`],
//! as well as saved-plan verification output.
//!
//! While [`super::render_package_plan`] and
//! [`super::render_package_diff_markdown`] render the package diff, this
//! module renders write-path findings (ownership conflicts, admission
//! refusals, prune outcomes, unchecked resources, and object write/delete
//! counts) and three-way drift findings.

use std::fmt::Write;

use crate::output;

use kix::plan::document::{
    AdmissionRefusal, Checked, FieldNotKept, MadeBy, NotCheckedReason, NotKept, Plan, PruneFate,
    RefusalReason, UncheckedReason, WriteChange,
};
use kix::plan::origin::ChangeLabel;
use kix::plan::saved::{Comparison, Rule};

/// Return the drift annotation tag for a field change in text output, or an
/// empty string for committed changes.
pub fn label_tag(labels: &[ChangeLabel]) -> String {
    if labels.contains(&ChangeLabel::RevertsDrift) {
        output::yellow("(reverts drift)").into_owned()
    } else if labels.contains(&ChangeLabel::DriftKept) {
        output::dim("(drift; deploy leaves this object alone)").into_owned()
    } else {
        String::new()
    }
}

/// Render the text plan sections that follow the package diff.
pub fn render_text(plan: &Plan) -> String {
    let mut out = String::new();
    write_stops(&mut out, plan);
    write_not_kept(&mut out, plan);
    write_drift(&mut out, plan);
    write_prune(&mut out, plan);
    write_not_checked(&mut out, plan);
    write_objects(&mut out, plan);
    out
}

/// Write the object write/delete summary, plan digest, and count of unchanged
/// objects re-applied from earlier builds.
fn write_objects(out: &mut String, plan: &Plan) {
    let (Some(objects), Some(digest)) = (&plan.objects, &plan.objects_digest) else {
        return;
    };
    let _ = writeln!(out);
    let _ = writeln!(
        out,
        "{} {} written, {} deleted {}",
        output::bold("Objects:"),
        objects.writes.len(),
        objects.deletes.len(),
        output::dim(&format!("({digest})")),
    );
    let reapplied = objects
        .writes
        .iter()
        .filter(|w| w.change == WriteChange::Reapplied)
        .count();
    if reapplied > 0 {
        let _ = writeln!(
            out,
            "  {} {reapplied} written again unchanged: a build this cluster ran holds the same file",
            output::yellow("↻"),
        );
    }
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

/// Write the fields Kubernetes would not keep as the build sets them. The
/// deploy goes on, so this is a warning, not a stop.
fn write_not_kept(out: &mut String, plan: &Plan) {
    if plan.not_kept.is_empty() {
        return;
    }
    let n = plan.not_kept.len();
    let _ = writeln!(out);
    let _ = writeln!(
        out,
        "{}",
        output::yellow(&format!(
            "Kubernetes would not keep {n} field{} as the build sets {}:",
            if n == 1 { "" } else { "s" },
            if n == 1 { "it" } else { "them" },
        ))
    );
    for f in &plan.not_kept {
        let _ = writeln!(
            out,
            "  {} {} {}",
            output::yellow("!"),
            f.resource,
            not_kept_detail(f, false),
        );
    }
    let _ = writeln!(
        out,
        "      {}",
        output::dim(
            "a CRD's schema drops a field it does not declare, and a mutating admission webhook can change a value; the deploy still applies the object"
        )
    );
}

/// Describe one field Kubernetes would not keep, after its resource. In
/// Markdown, paths and values are code.
fn not_kept_detail(f: &FieldNotKept, markdown: bool) -> String {
    let code = |s: String| if markdown { format!("`{s}`") } else { s };
    let path = code(f.path.trim_start_matches("$.").to_string());
    let sent = code(compact(Some(&f.sent)));
    match (f.change, &f.stored) {
        (NotKept::Changed, Some(stored)) => format!(
            "{path} changed (sent {sent}, stored {})",
            code(compact(Some(stored)))
        ),
        _ => format!("{path} dropped (sent {sent})"),
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

/// Render the drift section of `plan` as text, for a comparison that found no
/// other difference.
pub fn render_drift_text(plan: &Plan) -> String {
    let mut out = String::new();
    write_drift(&mut out, plan);
    out
}

/// Render the drift section of `plan` as Markdown, for a comparison that found
/// no other difference.
pub fn render_drift_markdown(plan: &Plan) -> String {
    let mut out = String::new();
    write_drift_markdown(&mut out, plan);
    out
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
                let _ = writeln!(
                    out,
                    "  {} {} {}",
                    output::yellow("↺"),
                    d.resource,
                    drift_detail(d),
                );
                let fate = match (d.reverted, conflict_with(plan, d)) {
                    (true, Some(owners)) => output::yellow(&format!(
                        "the deploy stops on an ownership conflict with {owners} unless run with --force-conflicts"
                    ))
                    .into_owned(),
                    (true, None) => {
                        output::yellow("the deploy puts the deployed value back").into_owned()
                    }
                    (false, Some(owners)) => output::dim(&format!(
                        "the deploy leaves this object alone; --reconcile stops on an ownership conflict with {owners} unless run with --force-conflicts"
                    ))
                    .into_owned(),
                    (false, None) => output::dim(
                        "the deploy leaves this object alone; --reconcile reverts it",
                    )
                    .into_owned(),
                };
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
    if let Some(line) = drift_unchecked_line(plan) {
        let _ = writeln!(out, "{}", output::dim(&line));
    }
}

/// Return the managers an apply of `d`'s object would conflict with, joined
/// for display. Server-side apply refuses to change a field another manager
/// owns unless forced, so a deploy that sets the deployed value back stops
/// there. A field at the deployed value is shared without a conflict.
fn conflict_with(plan: &Plan, d: &kix::plan::document::DriftChange) -> Option<String> {
    let forced = plan.flags.as_ref().is_some_and(|f| f.force_conflicts);
    (!d.managers.is_empty() && d.live != d.deployed && !forced).then(|| d.managers.join(", "))
}

/// Return the note on how many live objects the drift check could not judge,
/// or `None` when it judged them all.
fn drift_unchecked_line(plan: &Plan) -> Option<String> {
    match plan.drift_unchecked {
        0 => None,
        1 => {
            Some("1 object not checked for drift: it has no Kix stamp or no field records.".into())
        }
        n => Some(format!(
            "{n} objects not checked for drift: they have no Kix stamp or no field records."
        )),
    }
}

/// Describe one drift entry after its resource: the field, its live and
/// deployed values, and who set it. The deployed value is left out when it is
/// not known.
fn drift_detail(d: &kix::plan::document::DriftChange) -> String {
    if d.path == "$" {
        return "fields Kix applied have changed; Kubernetes recorded no other tool as their owner"
            .into();
    }
    let by = if d.managers.is_empty() {
        String::new()
    } else {
        format!(", set by {}", d.managers.join(", "))
    };
    let deployed = match &d.deployed {
        Some(v) => format!(", {} deployed", compact(Some(v))),
        None => String::new(),
    };
    format!(
        "{}: {} live{deployed}{by}",
        d.path.trim_start_matches("$."),
        compact(d.live.as_ref()),
    )
}

fn write_drift_markdown(out: &mut String, plan: &Plan) {
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
            let fate = match (d.reverted, conflict_with(plan, d)) {
                (true, Some(owners)) => format!(
                    "the deploy stops on an ownership conflict with {owners} unless run with `--force-conflicts`"
                ),
                (true, None) => "the deploy puts the deployed value back".into(),
                (false, Some(owners)) => format!(
                    "the deploy leaves this object alone; `--reconcile` stops on an ownership conflict with {owners} unless run with `--force-conflicts`"
                ),
                (false, None) => "the deploy leaves this object alone".into(),
            };
            let _ = writeln!(
                out,
                "- `{}` {}; {fate}",
                d.resource,
                drift_detail_markdown(d),
            );
        }
        let _ = writeln!(out);
    }
    if let Some(line) = drift_unchecked_line(plan) {
        let _ = writeln!(out, "{line}");
        let _ = writeln!(out);
    }
}

fn drift_detail_markdown(d: &kix::plan::document::DriftChange) -> String {
    if d.path == "$" {
        return "fields Kix applied have changed; Kubernetes recorded no other tool as their owner"
            .into();
    }
    let by = if d.managers.is_empty() {
        String::new()
    } else {
        format!(", set by `{}`", d.managers.join("`, `"))
    };
    let deployed = match &d.deployed {
        Some(v) => format!(", `{}` deployed", compact(Some(v))),
        None => String::new(),
    };
    format!(
        "`{}`: `{}` live{deployed}{by}",
        d.path.trim_start_matches("$."),
        compact(d.live.as_ref()),
    )
}

/// Format a JSON value on a single line (truncated to 60 characters with byte
/// length) for drift output.
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
        "{} {} orphans stay:",
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
                UncheckedReason::CrdChangedByThisDeploy => {
                    "its CRD is changed by this deploy, and was checked as it is now"
                }
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

/// Render the Markdown plan sections that follow the package diff.
pub fn render_markdown(plan: &Plan) -> String {
    let mut out = String::new();
    let conflicts = plan.conflicts.items();
    let refusals = plan.admission.items();
    let prune_refused: Vec<_> = plan
        .prune
        .items()
        .iter()
        .filter(|p| p.fate == PruneFate::DeleteRefused)
        .collect();
    if !conflicts.is_empty() || !refusals.is_empty() || !prune_refused.is_empty() {
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
        for p in prune_refused {
            let _ = writeln!(out, "- `{}`: prune delete refused", p.resource);
            if let Some(why) = &p.detail {
                let _ = writeln!(out, "  > {}", why.replace('\n', " "));
            }
        }
        let _ = writeln!(out);
    }
    if !plan.not_kept.is_empty() {
        let _ = writeln!(out, "#### :warning: Kubernetes would not keep these fields");
        let _ = writeln!(out);
        let _ = writeln!(
            out,
            "The deploy still applies these objects, but the fields would not hold the build's values:"
        );
        let _ = writeln!(out);
        for f in &plan.not_kept {
            let _ = writeln!(out, "- `{}` {}", f.resource, not_kept_detail(f, true));
        }
        let _ = writeln!(out);
    }
    write_drift_markdown(&mut out, plan);
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

/// Render the result of comparing a live plan against the saved plan at `path`.
pub fn render_comparison(c: &Comparison, reviewed: &Plan, path: &str) -> String {
    let mut out = String::new();
    let path = match &c.plan_sha256 {
        Some(sha) => format!("{path}, {sha}"),
        None => path.to_string(),
    };
    if c.matches {
        let _ = writeln!(
            out,
            "{}",
            output::green(&format!("The reviewed plan matches ({path})."))
        );
    } else {
        let _ = writeln!(
            out,
            "{}",
            output::red(&format!("The reviewed plan no longer matches ({path}):"))
        );
        for m in &c.mismatches {
            for (i, item) in m.items.iter().enumerate() {
                let label = if i == 0 {
                    format!("[{}]", m.rule.label())
                } else {
                    String::new()
                };
                let _ = writeln!(out, "  {label:<20} {item}");
            }
        }
    }
    if !c.skipped.is_empty() {
        let what: Vec<&str> = c
            .skipped
            .iter()
            .map(|r| match r {
                Rule::NewRefusal => "conflicts and admission",
                Rule::NewRevertedDrift => "drift",
                Rule::NewPruneDelete => "prune",
                _ => r.label(),
            })
            .collect();
        let kind = if reviewed.made_by == MadeBy::LiveRead {
            "the reviewed plan is a kix diff"
        } else {
            "the reviewed plan did not check them"
        };
        let _ = writeln!(
            out,
            "{}",
            output::dim(&format!("Not compared, {kind}: {}.", what.join(", ")))
        );
    }
    if let Some((r, f)) = &c.kix_differs {
        let _ = writeln!(
            out,
            "{}",
            output::yellow(&format!(
                "note: the plan was made by {r}, and this deploy runs {f}. The deploy writes \
                 and deletes the objects the plan lists, so this is not refused."
            ))
        );
    }
    if !c.matches {
        let _ = writeln!(out, "Review a new plan, or deploy without --plan.");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use kix::eval::store_graph::StoreGraph;
    use kix::plan::document::{Build, Detail, DriftChange};

    fn plan_with(drift: Vec<DriftChange>) -> Plan {
        let graph = StoreGraph::empty("c");
        let mut plan = Plan::new(
            crate::plan::kix_build(),
            MadeBy::LiveRead,
            "c",
            Build::of(&graph),
            &kix::plan::diff_graphs(&graph, &graph),
            Detail::Plain,
            &[],
            NotCheckedReason::ReadOnly,
        );
        plan.drift = Checked::found(drift);
        plan
    }

    fn drift(managers: &[&str], reverted: bool) -> DriftChange {
        DriftChange {
            resource: "Deployment/web@app".into(),
            path: "$.spec.replicas".into(),
            deployed: Some(serde_json::json!(1)),
            live: Some(serde_json::json!(3)),
            managers: managers.iter().map(|m| m.to_string()).collect(),
            reverted,
        }
    }

    /// A field another manager owns stops the deploy on an ownership
    /// conflict, unless the plan forces conflicts. A field Kubernetes
    /// records no other owner for is put back.
    #[test]
    fn drift_another_manager_owns_says_the_deploy_stops() {
        let owned = plan_with(vec![drift(&["kubectl-scale"], true)]);
        let text = render_drift_text(&owned);
        assert!(
            text.contains(
                "the deploy stops on an ownership conflict with kubectl-scale unless run with --force-conflicts"
            ),
            "{text}"
        );
        assert!(render_drift_markdown(&owned).contains("ownership conflict with kubectl-scale"));

        let kept = render_drift_text(&plan_with(vec![drift(&["kubectl-scale"], false)]));
        assert!(
            kept.contains("--reconcile stops on an ownership conflict"),
            "{kept}"
        );

        let mut forced = owned.clone();
        forced.flags = Some(kix::plan::document::PlanFlags {
            prune: false,
            prune_mode: None,
            reconcile: false,
            force_conflicts: true,
            accept_migrations: false,
        });
        let text = render_drift_text(&forced);
        assert!(
            text.contains("the deploy puts the deployed value back"),
            "{text}"
        );

        let unowned = render_drift_text(&plan_with(vec![drift(&[], true)]));
        assert!(
            unowned.contains("the deploy puts the deployed value back"),
            "{unowned}"
        );
    }

    #[test]
    fn fields_kubernetes_would_not_keep_are_a_warning() {
        let mut plan = plan_with(Vec::new());
        assert!(!render_text(&plan).contains("would not keep"));
        assert!(!render_markdown(&plan).contains("would not keep"));
        plan.not_kept = vec![
            FieldNotKept {
                resource: "Widget/w@app".into(),
                path: "$.spec.colour".into(),
                change: NotKept::Dropped,
                sent: serde_json::json!("red"),
                stored: None,
            },
            FieldNotKept {
                resource: "Deployment/web@app".into(),
                path: "$.spec.replicas".into(),
                change: NotKept::Changed,
                sent: serde_json::json!(2),
                stored: Some(serde_json::json!(5)),
            },
        ];
        let text = render_text(&plan);
        assert!(
            text.contains("Kubernetes would not keep 2 fields as the build sets them:"),
            "{text}"
        );
        assert!(
            text.contains("Widget/w@app spec.colour dropped (sent \"red\")"),
            "{text}"
        );
        assert!(
            text.contains("Deployment/web@app spec.replicas changed (sent 2, stored 5)"),
            "{text}"
        );
        let markdown = render_markdown(&plan);
        assert!(
            markdown.contains("#### :warning: Kubernetes would not keep these fields"),
            "{markdown}"
        );
        assert!(
            markdown
                .contains("- `Deployment/web@app` `spec.replicas` changed (sent `2`, stored `5`)"),
            "{markdown}"
        );
        assert!(!plan.stops() && !plan.has_changes());
    }

    #[test]
    fn objects_drift_cannot_judge_are_counted() {
        let mut plan = plan_with(Vec::new());
        assert!(render_drift_text(&plan).is_empty());
        plan.drift_unchecked = 1;
        assert!(
            render_drift_text(&plan).contains(
                "1 object not checked for drift: it has no Kix stamp or no field records."
            )
        );
    }
}
