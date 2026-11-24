//! Text and Markdown rendering for the non-package sections of a [`Plan`],
//! as well as saved-plan verification output.
//!
//! While [`super::render_package_plan`] and
//! [`super::render_package_diff_markdown`] render the package diff, this
//! module renders write-path findings (ownership conflicts, admission
//! refusals, prune outcomes, unchecked resources, and object write/delete
//! counts) and three-way drift findings.

use std::fmt::{self, Write};

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
    written(|out| {
        write_stops(out, plan)?;
        write_not_kept(out, plan)?;
        write_drift(out, plan)?;
        write_prune(out, plan)?;
        write_not_checked(out, plan)?;
        write_objects(out, plan)
    })
}

/// Return the text that `write` writes. Writing to a `String` cannot fail.
fn written(write: impl FnOnce(&mut String) -> fmt::Result) -> String {
    let mut out = String::new();
    write(&mut out).expect("writing to a String cannot fail");
    out
}

/// Write the counts of objects the deploy would write and delete, the plan
/// digest, and the count of unchanged objects written again from earlier
/// builds. An unchanged Job that runs again only if its last run failed is
/// not counted: the Job rerun lines name the ones that will.
fn write_objects(out: &mut String, plan: &Plan) -> fmt::Result {
    let (Some(objects), Some(digest)) = (&plan.objects, &plan.objects_digest) else {
        return Ok(());
    };
    let writes: Vec<_> = objects
        .writes
        .iter()
        .filter(|w| w.change.certain())
        .collect();
    writeln!(out)?;
    writeln!(
        out,
        "{} {} to write, {} to delete {}",
        output::bold("Objects:"),
        writes.len(),
        objects.deletes.len(),
        output::dim(&format!("({digest})")),
    )?;
    let reapplied = writes
        .iter()
        .filter(|w| w.change == WriteChange::Reapplied)
        .count();
    if reapplied > 0 {
        writeln!(
            out,
            "  {} {reapplied} written again unchanged from an earlier deploy (changes nothing unless edited on the cluster)",
            output::yellow("↻"),
        )?;
    }
    Ok(())
}

fn write_stops(out: &mut String, plan: &Plan) -> fmt::Result {
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
        return Ok(());
    }
    writeln!(out)?;
    writeln!(
        out,
        "{}",
        output::red(&format!(
            "The deploy would stop on {count} write{}:",
            if count == 1 { "" } else { "s" }
        ))
    )?;
    for c in conflicts {
        writeln!(
            out,
            "  {} {} {}",
            output::red("✗"),
            c.resource,
            output::red("field ownership conflict"),
        )?;
        for o in &c.owners {
            writeln!(out, "      {} owns {}", o.manager, o.fields.join(", "))?;
        }
        writeln!(
            out,
            "      {}",
            output::dim(
                "--force-conflicts takes the fields; `ownership.cede` on the resource leaves them to the other manager"
            )
        )?;
    }
    for r in refusals {
        writeln!(
            out,
            "  {} {} {}",
            output::red("✗"),
            r.resource,
            output::red(&refusal_title(r)),
        )?;
        writeln!(out, "      {}", output::dim(&r.message))?;
    }
    for p in prune_refused {
        writeln!(
            out,
            "  {} {} {}",
            output::red("✗"),
            p.resource,
            output::red("prune delete refused"),
        )?;
        if let Some(detail) = &p.detail {
            writeln!(out, "      {}", output::dim(detail))?;
        }
    }
    Ok(())
}

/// Write the fields Kubernetes would not keep as the build sets them. The
/// deploy goes on, so this is a warning, not a stop.
fn write_not_kept(out: &mut String, plan: &Plan) -> fmt::Result {
    if plan.not_kept.is_empty() {
        return Ok(());
    }
    let n = plan.not_kept.len();
    writeln!(out)?;
    writeln!(
        out,
        "{}",
        output::yellow(&format!(
            "Kubernetes would not keep {n} field{} as the build sets {}:",
            if n == 1 { "" } else { "s" },
            if n == 1 { "it" } else { "them" },
        ))
    )?;
    for f in &plan.not_kept {
        writeln!(
            out,
            "  {} {} {}",
            output::yellow("!"),
            f.resource,
            not_kept_detail(f, false),
        )?;
    }
    writeln!(
        out,
        "      {}",
        output::dim(
            "a CRD's schema drops a field it does not declare, and a mutating admission webhook can change a value; the deploy still applies the object"
        )
    )?;
    Ok(())
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
        (RefusalReason::WebhookUnreachable, Some(w)) => {
            format!("admission webhook {w} is unreachable")
        }
        (RefusalReason::WebhookUnreachable, None) => "an admission webhook is unreachable".into(),
        (RefusalReason::Other, _) => "refused".into(),
    }
}

/// Render the drift section of `plan` as text, for a comparison that found no
/// other difference.
pub fn render_drift_text(plan: &Plan) -> String {
    written(|out| write_drift(out, plan))
}

/// Render the drift section of `plan` as Markdown, for a comparison that found
/// no other difference.
pub fn render_drift_markdown(plan: &Plan) -> String {
    written(|out| write_drift_markdown(out, plan))
}

fn write_drift(out: &mut String, plan: &Plan) -> fmt::Result {
    match &plan.drift {
        Checked::Checked { items } if !items.is_empty() => {
            writeln!(out)?;
            writeln!(
                out,
                "{}",
                output::yellow(&format!(
                    "Drift: {} field(s) on the live cluster differ from the deployed build:",
                    items.len(),
                ))
            )?;
            for d in items {
                writeln!(
                    out,
                    "  {} {} {}",
                    output::yellow("↺"),
                    d.resource,
                    drift_detail(d),
                )?;
                let fate = match (d.reverted, conflict_with(plan, d)) {
                    (true, Some(owners)) => output::yellow(&format!(
                        "the deploy writes this object, which stops on a field ownership conflict with {owners} unless run with --force-conflicts"
                    ))
                    .into_owned(),
                    (true, None) => {
                        output::yellow("the deploy writes this object and restores the deployed value")
                            .into_owned()
                    }
                    (false, Some(owners)) => output::dim(&format!(
                        "the deploy leaves this object alone; --reconcile stops on a field ownership conflict with {owners} unless run with --force-conflicts"
                    ))
                    .into_owned(),
                    (false, None) => output::dim(
                        "the deploy leaves this object alone (--reconcile restores the deployed value)",
                    )
                    .into_owned(),
                };
                writeln!(out, "      {fate}")?;
            }
        }
        Checked::NotChecked {
            reason: NotCheckedReason::DeployedBuildUnavailable,
        } => {
            writeln!(out)?;
            writeln!(
                out,
                "{}",
                output::dim(
                    "Drift not checked: the deployed build is not on this machine, so Kix cannot tell which differences come from this build and which come from edits on the cluster (the deploy applies everything in the plan)."
                )
            )?;
        }
        _ => {}
    }
    if let Some(line) = drift_unchecked_line(plan) {
        writeln!(out, "{}", output::dim(&line))?;
    }
    Ok(())
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
        n => Some(format!(
            "{n} object(s) not checked for drift: missing `{}` annotation (an older Kix deployed them; the next deploy adds it) or missing Kubernetes field ownership entry for Kix.",
            kix::manifest::keys::APPLIED_HASH
        )),
    }
}

/// Describe one drift entry after its resource: the field, its live and
/// deployed values, and who set it. The deployed value is left out when it is
/// not known.
fn drift_detail(d: &kix::plan::document::DriftChange) -> String {
    if d.path == "$" {
        return "fields Kix applied changed on the live cluster (no other field manager recorded)"
            .into();
    }
    let by = if d.managers.is_empty() {
        String::new()
    } else {
        format!(", set by {}", d.managers.join(", "))
    };
    let (live, deployed) = compact_pair(d.live.as_ref(), d.deployed.as_ref());
    let deployed = match deployed {
        Some(v) => format!(", {v} in deployed build"),
        None => String::new(),
    };
    format!(
        "{}: {live} live{deployed}{by}",
        d.path.trim_start_matches("$."),
    )
}

/// Return the live and deployed values for one line of text. Two strings of
/// several lines that start alike show the first line where they differ, so
/// the reader sees what changed rather than the same opening twice.
fn compact_pair(
    live: Option<&serde_json::Value>,
    deployed: Option<&serde_json::Value>,
) -> (String, Option<String>) {
    if let (Some(serde_json::Value::String(a)), Some(serde_json::Value::String(b))) =
        (live, deployed)
        && a != b
    {
        let (al, bl): (Vec<&str>, Vec<&str>) = (a.lines().collect(), b.lines().collect());
        let at = (0..al.len().max(bl.len()))
            .find(|&i| al.get(i) != bl.get(i))
            .unwrap_or(0);
        if at > 0 {
            let line = |lines: &[&str], full: &str| {
                let text = lines.get(at).map_or("", |l| l.trim());
                let cut = &text[..text.floor_char_boundary(60)];
                let more = if cut.len() < text.len() { "…" } else { "" };
                format!("line {}: {cut:?}{more} ({} bytes)", at + 1, full.len())
            };
            return (line(&al, a), Some(line(&bl, b)));
        }
    }
    (compact(live), deployed.map(|v| compact(Some(v))))
}

fn write_drift_markdown(out: &mut String, plan: &Plan) -> fmt::Result {
    if let Checked::Checked { items } = &plan.drift
        && !items.is_empty()
    {
        writeln!(out, "#### Drift")?;
        writeln!(out)?;
        writeln!(
            out,
            "Fields where the live cluster differs from the deployed build:"
        )?;
        writeln!(out)?;
        for d in items {
            let fate = match (d.reverted, conflict_with(plan, d)) {
                (true, Some(owners)) => format!(
                    "the deploy writes this object, which stops on a field ownership conflict with `{owners}` unless run with `--force-conflicts`"
                ),
                (true, None) => {
                    "the deploy writes this object and restores the deployed value".into()
                }
                (false, Some(owners)) => format!(
                    "the deploy leaves this object alone; `--reconcile` stops on a field ownership conflict with `{owners}` unless run with `--force-conflicts`"
                ),
                (false, None) => {
                    "the deploy leaves this object alone; `--reconcile` restores the deployed value"
                        .into()
                }
            };
            writeln!(
                out,
                "- `{}` {} ({fate})",
                d.resource,
                drift_detail_markdown(d),
            )?;
        }
        writeln!(out)?;
    }
    if let Some(line) = drift_unchecked_line(plan) {
        writeln!(out, "{line}")?;
        writeln!(out)?;
    }
    Ok(())
}

fn drift_detail_markdown(d: &kix::plan::document::DriftChange) -> String {
    if d.path == "$" {
        return "fields Kix applied changed on the live cluster, no other field manager recorded"
            .into();
    }
    let by = if d.managers.is_empty() {
        String::new()
    } else {
        format!(", set by `{}`", d.managers.join("`, `"))
    };
    let deployed = match &d.deployed {
        Some(v) => format!(", `{}` in deployed build", compact(Some(v))),
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

fn write_prune(out: &mut String, plan: &Plan) -> fmt::Result {
    let items = plan.prune.items();
    let shared: Vec<_> = items
        .iter()
        .filter(|p| matches!(p.fate, PruneFate::KeptShared | PruneFate::KeptChanged))
        .collect();
    if shared.is_empty() {
        return Ok(());
    }
    writeln!(out)?;
    writeln!(
        out,
        "{} {} object(s) that left the build stay on the cluster:",
        output::bold("Prune:"),
        shared.len()
    )?;
    for p in shared {
        writeln!(
            out,
            "  {} {} {}",
            output::yellow("="),
            p.resource,
            output::dim(p.detail.as_deref().unwrap_or("")),
        )?;
    }
    Ok(())
}

fn write_not_checked(out: &mut String, plan: &Plan) -> fmt::Result {
    if plan.made_by == MadeBy::DryRun && !plan.not_checked.is_empty() {
        writeln!(out)?;
        writeln!(
            out,
            "{}",
            output::dim(&format!(
                "Not checked by the dry run ({}); their changes come from comparing builds:",
                plan.not_checked.len()
            ))
        )?;
        let mut groups: Vec<(UncheckedReason, Vec<&str>)> = Vec::new();
        for o in &plan.not_checked {
            match groups.iter_mut().find(|(r, _)| *r == o.reason) {
                Some((_, names)) => names.push(&o.resource),
                None => groups.push((o.reason, vec![&o.resource])),
            }
        }
        for (reason, names) in groups {
            let why = match reason {
                UncheckedReason::CrdCreatedByThisDeploy => {
                    "uses a CustomResourceDefinition created by this deploy"
                }
                UncheckedReason::CrdChangedByThisDeploy => {
                    "uses a CustomResourceDefinition changed by this deploy, so it was checked against the definition currently on the cluster"
                }
                UncheckedReason::NamespaceCreatedByThisDeploy => {
                    "is in a Namespace created by this deploy"
                }
                UncheckedReason::WebhookNoDryRun => {
                    "calls an admission webhook that does not support dry run"
                }
                UncheckedReason::WebhookBackendWrittenByThisDeploy => {
                    "calls an admission webhook whose Service is missing or not ready, and this deploy writes that Service or the package that serves it"
                }
                UncheckedReason::DependencyNotChecked => {
                    "not reached by the dry run (for example, cancelled early)"
                }
            };
            writeln!(out, "  {} {} {}:", output::dim("?"), names.len(), why)?;
            for name in names.iter().take(5) {
                writeln!(out, "      {}", output::dim(name))?;
            }
            if names.len() > 5 {
                writeln!(
                    out,
                    "      {}",
                    output::dim(&format!(
                        "and {} more (-o json lists them)",
                        names.len() - 5
                    ))
                )?;
            }
        }
    }
    if !plan.has_changes() {
        return Ok(());
    }
    match plan.made_by {
        MadeBy::DryRun => {
            writeln!(out)?;
            writeln!(
                out,
                "{}",
                output::dim(
                    "Not checked by any preview: whether Pods start, pull their images, and pass their readiness probes."
                )
            )?;
        }
        MadeBy::LiveRead => {
            writeln!(out)?;
            writeln!(
                out,
                "{}",
                output::dim(
                    "Made by a read-only comparison with the cluster. Not checked: admission webhooks, admission policies, field ownership conflicts, and invalid objects; `kix plan` checks them."
                )
            )?;
        }
        MadeBy::Builds => {
            writeln!(out)?;
            writeln!(
                out,
                "{}",
                output::dim(
                    "Made by comparing two builds, with no cluster read. Not checked: live cluster drift, admission webhooks, admission policies, field ownership conflicts, and invalid objects."
                )
            )?;
        }
    }
    Ok(())
}

/// Render the Kix library's warnings for the new build as a Markdown
/// section, or nothing when there are none.
pub fn render_warnings_markdown(plan: &Plan) -> String {
    written(|out| write_warnings_markdown(out, plan))
}

fn write_warnings_markdown(out: &mut String, plan: &Plan) -> fmt::Result {
    if plan.warnings.is_empty() {
        return Ok(());
    }
    writeln!(
        out,
        "#### :warning: Warnings from the Kix library ({})",
        plan.warnings.len()
    )?;
    writeln!(out)?;
    let body: String = plan
        .warnings
        .iter()
        .map(|w| w.describe("  ") + "\n")
        .collect();
    let fence = fence_for(&body);
    write!(out, "{fence}text\n{body}{fence}\n")?;
    writeln!(out)
}

/// Return a Markdown code fence that `body` cannot close: a run of
/// backticks longer than any run in `body`, and at least three. A warning
/// can hold text from a bundle another machine made.
fn fence_for(body: &str) -> String {
    let longest = body.split(|c| c != '`').map(str::len).max().unwrap_or(0);
    "`".repeat(longest.max(2) + 1)
}

/// Render the Markdown plan sections that follow the package diff.
pub fn render_markdown(plan: &Plan) -> String {
    written(|out| write_markdown(out, plan))
}

fn write_markdown(out: &mut String, plan: &Plan) -> fmt::Result {
    write_warnings_markdown(out, plan)?;
    let conflicts = plan.conflicts.items();
    let refusals = plan.admission.items();
    let prune_refused: Vec<_> = plan
        .prune
        .items()
        .iter()
        .filter(|p| p.fate == PruneFate::DeleteRefused)
        .collect();
    if !conflicts.is_empty() || !refusals.is_empty() || !prune_refused.is_empty() {
        writeln!(out, "#### :x: The deploy would stop on these writes")?;
        writeln!(out)?;
        for c in conflicts {
            let owners: Vec<String> = c
                .owners
                .iter()
                .map(|o| format!("`{}` owns `{}`", o.manager, o.fields.join("`, `")))
                .collect();
            writeln!(
                out,
                "- `{}`: field ownership conflict, {}",
                c.resource,
                owners.join("; ")
            )?;
        }
        for r in refusals {
            writeln!(out, "- `{}`: {}", r.resource, refusal_title(r))?;
            writeln!(out, "  > {}", r.message.replace('\n', " "))?;
        }
        for p in prune_refused {
            writeln!(out, "- `{}`: prune delete refused", p.resource)?;
            if let Some(why) = &p.detail {
                writeln!(out, "  > {}", why.replace('\n', " "))?;
            }
        }
        writeln!(out)?;
    }
    if !plan.not_kept.is_empty() {
        writeln!(out, "#### :warning: Kubernetes would not keep these fields")?;
        writeln!(out)?;
        writeln!(
            out,
            "The deploy still applies these objects, but the fields would not hold the build's values:"
        )?;
        writeln!(out)?;
        for f in &plan.not_kept {
            writeln!(out, "- `{}` {}", f.resource, not_kept_detail(f, true))?;
        }
        writeln!(out)?;
    }
    write_drift_markdown(out, plan)?;
    if !plan.not_checked.is_empty() {
        writeln!(
            out,
            "<details><summary>Not checked by the dry run ({})</summary>",
            plan.not_checked.len()
        )?;
        writeln!(out)?;
        for o in &plan.not_checked {
            writeln!(out, "- `{}`: {}", o.resource, o.detail)?;
        }
        writeln!(out)?;
        writeln!(out, "</details>")?;
        writeln!(out)?;
    }
    let note = match plan.made_by {
        MadeBy::DryRun => {
            "Made by a server-side dry run. Not checked: whether Pods start, pull their images, and pass their readiness probes."
        }
        MadeBy::LiveRead => {
            "Made by a read-only comparison with the cluster. Not checked: admission webhooks, admission policies, field ownership conflicts, and invalid objects; `kix plan` checks them."
        }
        MadeBy::Builds => {
            "Made by comparing two builds, with no cluster read. Not checked: live cluster drift, admission webhooks, admission policies, field ownership conflicts, and invalid objects."
        }
    };
    writeln!(out, "> {note}")?;
    writeln!(out)
}

/// Render the result of comparing a live plan against the saved plan at `path`,
/// for a deploy of `cluster`.
pub fn render_comparison(c: &Comparison, reviewed: &Plan, path: &str, cluster: &str) -> String {
    written(|out| write_comparison(out, c, reviewed, path, cluster))
}

fn write_comparison(
    out: &mut String,
    c: &Comparison,
    reviewed: &Plan,
    path: &str,
    cluster: &str,
) -> fmt::Result {
    let file = path;
    let path = match &c.plan_sha256 {
        Some(sha) => format!("{path}, {sha}"),
        None => path.to_string(),
    };
    if c.matches {
        writeln!(
            out,
            "{}",
            output::green(&format!("The reviewed plan matches ({path})."))
        )?;
    } else {
        writeln!(
            out,
            "{}",
            output::red(&format!("The reviewed plan no longer matches ({path})."))
        )?;
        writeln!(out, "Nothing was applied to the cluster.")?;
        writeln!(out)?;
        writeln!(out, "  Differences since '{file}' was saved:")?;
        for m in &c.mismatches {
            for (i, item) in m.items.iter().enumerate() {
                let label = if i == 0 {
                    format!("[{}]", m.rule.label())
                } else {
                    String::new()
                };
                writeln!(out, "    {label:<20} {item}")?;
            }
        }
        writeln!(out)?;
    }
    if !c.skipped.is_empty() {
        let what: Vec<&str> = c
            .skipped
            .iter()
            .map(|r| match r {
                Rule::NewRefusal => "admission and ownership conflicts",
                Rule::NewRevertedDrift => "live drift",
                Rule::NewPruneDelete => "`--prune` deletions",
                _ => r.label(),
            })
            .collect();
        let kind = if reviewed.made_by == MadeBy::LiveRead {
            "because the reviewed plan was saved by `kix diff` or `kix plan --read-only`"
        } else {
            "because the reviewed plan did not check them"
        };
        writeln!(
            out,
            "{}",
            output::dim(&format!("  Not compared, {kind}: {}.", join_list(&what)))
        )?;
    }
    if let Some((r, f)) = &c.kix_differs {
        writeln!(
            out,
            "{}",
            output::yellow(&format!(
                "  Note: the plan was saved by {r}, and this deploy runs {f}. The deploy writes \
                 and deletes the exact objects the plan lists, so this version difference is \
                 allowed."
            ))
        )?;
    }
    if !c.matches {
        writeln!(out)?;
        writeln!(out, "  Next:")?;
        writeln!(
            out,
            "    Save and review a new plan with `kix plan {cluster} --out {file}`, or run `kix deploy {cluster}` without `--plan`."
        )?;
    }
    Ok(())
}

/// Join `items` as an English list with an Oxford comma.
fn join_list(items: &[&str]) -> String {
    match items {
        [] => String::new(),
        [one] => one.to_string(),
        [a, b] => format!("{a} and {b}"),
        [rest @ .., last] => format!("{}, and {last}", rest.join(", ")),
    }
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

    /// A warning that holds a code fence stays inside the warnings block,
    /// because the block's fence is longer than any run of backticks in it.
    #[test]
    fn a_warning_cannot_close_the_warnings_fence() {
        let mut plan = plan_with(Vec::new());
        plan.warnings = vec![kix::eval::library_record::LibraryRecord {
            message: "before\n```\n# injected heading\n````".to_string(),
            ..Default::default()
        }];
        let text = render_warnings_markdown(&plan);
        let fences: Vec<&str> = text.lines().filter(|l| l.starts_with("```")).collect();
        assert_eq!(fences.first(), Some(&"`````text"), "{text}");
        assert_eq!(fences.last(), Some(&"`````"), "{text}");
        assert!(
            fences[1..fences.len() - 1].iter().all(|f| f.len() < 5),
            "{text}"
        );
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
                "the deploy writes this object, which stops on a field ownership conflict with kubectl-scale unless run with --force-conflicts"
            ),
            "{text}"
        );
        assert!(render_drift_markdown(&owned).contains("ownership conflict with `kubectl-scale`"));

        let kept = render_drift_text(&plan_with(vec![drift(&["kubectl-scale"], false)]));
        assert!(
            kept.contains("--reconcile stops on a field ownership conflict"),
            "{kept}"
        );

        let mut forced = owned.clone();
        forced.flags = Some(kix::plan::document::PlanFlags {
            prune: kix::cluster::scheduler::PrunePolicy::WarnOnly,
            reconcile: false,
            force_conflicts: true,
            accept_migrations: false,
        });
        let text = render_drift_text(&forced);
        assert!(
            text.contains("the deploy writes this object and restores the deployed value"),
            "{text}"
        );

        let unowned = render_drift_text(&plan_with(vec![drift(&[], true)]));
        assert!(
            unowned.contains("the deploy writes this object and restores the deployed value"),
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
        assert!(render_drift_text(&plan).contains(&format!(
            "1 object(s) not checked for drift: missing `{}` annotation",
            kix::manifest::keys::APPLIED_HASH
        )));
    }

    #[test]
    fn a_long_text_drift_shows_the_line_that_differs() {
        let live = serde_json::json!("server {\n  return 200 'old';\n}\n");
        let built = serde_json::json!("server {\n  return 200 'new';\n}\n");
        let (l, b) = compact_pair(Some(&live), Some(&built));
        assert_eq!(l, "line 2: \"return 200 'old';\" (31 bytes)");
        assert_eq!(
            b.as_deref(),
            Some("line 2: \"return 200 'new';\" (31 bytes)")
        );
    }
}
