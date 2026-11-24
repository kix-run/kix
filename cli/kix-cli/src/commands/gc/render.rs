//! Render `kix gc` plans, record retirement summaries, and confirmation prompts.

use std::io::Write;

use miette::{IntoDiagnostic, Result};

use crate::cli::GcArgs;
use crate::exit::{Exit, Stopped};
use crate::output;
use kix::cluster::activation::{Record, RetentionPolicy, RetireReason};
use kix::manifest::types::{ResourceId, to_manifest_value};

use super::plan::{GarbageEntry, RecordRetirement};

/// Print resources that carry the Kix label but no identity hash, and explain
/// why GC leaves them alone by default.
pub(super) fn print_unstamped(unstamped: &[GarbageEntry]) {
    println!();
    println!(
        "{} {} object(s) carry Kix's label but no Kix build annotation:",
        output::bold("No Kix build annotation:"),
        unstamped.len(),
    );
    for entry in unstamped {
        println!(
            "    {} {}/{}/{}",
            output::dim("?"),
            entry.id.namespace,
            entry.id.kind,
            entry.id.name,
        );
    }
    println!(
        "  {}",
        output::dim(
            "Kept running on the cluster, because Kix never applied them. \
             Pass `--include unstamped` to delete them too."
        ),
    );
}

/// Print objects that name no Activation record on a multi-cluster target, and
/// state whether `--include unattributed` includes them.
pub(super) fn print_unattributed(objects: &[kube::api::DynamicObject], included: bool) {
    println!();
    println!(
        "{} {} Kix-labeled object(s) name no deployment record on this cluster, and \
         another Kix cluster deploys here, so Kix cannot tell which cluster they belong to:",
        output::bold("No deployment record on this cluster:"),
        objects.len(),
    );
    let mut ids: Vec<ResourceId> = objects
        .iter()
        .map(|o| ResourceId::from_value(&to_manifest_value(o)))
        .collect();
    ids.sort();
    for rid in &ids {
        println!("    {} {rid}", output::dim("?"));
    }
    let note = if included {
        "--include unattributed: objects that name no deployment record on this cluster are checked against this build like this cluster's own objects."
    } else {
        "Kept running on the cluster. Review them and pass `--include unattributed` to check them against this build and delete any not in it."
    };
    println!("  {}", output::dim(note));
}

/// Print the copies of Kix objects that other programs made, and state
/// whether `--include copies` includes them.
pub(super) fn print_copies(objects: &[kube::api::DynamicObject], included: bool) {
    println!();
    println!(
        "{} {} object(s) carry Kix's labels, but Kix never wrote them (another \
         controller, usually an operator, copied the labels from an object Kix made):",
        output::bold("Copied labels:"),
        objects.len(),
    );
    let mut ids: Vec<ResourceId> = objects
        .iter()
        .map(|o| ResourceId::from_value(&to_manifest_value(o)))
        .collect();
    ids.sort();
    for rid in &ids {
        println!("    {} {rid}", output::dim("?"));
    }
    let note = if included {
        "--include copies: objects whose labels were copied by another program are checked against this build like Kix's own objects."
    } else {
        "Kept running on the cluster, because Kix did not make them. Pass `--include copies` to check them against this build and delete any not in it."
    };
    println!("  {}", output::dim(note));
}

/// Print the grouped per-resource garbage plan with reasons and owning activations.
pub(super) fn print_garbage_plan(garbage: &[GarbageEntry]) {
    use std::collections::BTreeMap;

    println!();
    println!(
        "{} ({} left the build, still on the cluster):",
        output::bold("Objects to delete"),
        garbage.len(),
    );

    let mut by_ns: BTreeMap<&str, BTreeMap<&str, Vec<&GarbageEntry>>> = BTreeMap::new();
    for entry in garbage {
        by_ns
            .entry(entry.id.namespace.as_str())
            .or_default()
            .entry(entry.id.kind.as_str())
            .or_default()
            .push(entry);
    }

    for (ns, by_kind) in &by_ns {
        println!();
        println!("  {}", output::bold(ns));
        for (kind, entries) in by_kind {
            for entry in entries {
                let hash_short = entry
                    .identity_hash
                    .as_deref()
                    .map(|h| format!(" (build {})", &h[..12.min(h.len())]))
                    .unwrap_or_default();
                println!(
                    "    {} {}/{}{}",
                    output::red("-"),
                    kind,
                    entry.id.name,
                    output::dim(&hash_short),
                );

                let reason_line = format!("reason: {}", entry.reason.label());
                println!("        {}", output::dim(&reason_line));
                if let Some(deleting) = &entry.deleting {
                    println!("        {}", output::yellow(&format!("already {deleting}")));
                }

                if let Some(pkg) = &entry.package {
                    let pkg_display = match &entry.package_namespace {
                        Some(pns) if pns != "_cluster" => format!("package: {pns}/{pkg}"),
                        _ => format!("package: {pkg}"),
                    };
                    println!("        {}", output::dim(&pkg_display));
                }
                if let Some(acts) = &entry.activations {
                    let acts_short: Vec<String> = acts
                        .split(',')
                        .map(|a| a.trim())
                        .filter(|a| !a.is_empty())
                        .map(|a| a[..12.min(a.len())].to_string())
                        .collect();
                    if !acts_short.is_empty() {
                        let line = format!("deployments: {}", acts_short.join(", "));
                        println!("        {}", output::dim(&line));
                    }
                }
            }
        }
    }
    println!();
}

/// Format `policy` as a human-readable summary clause.
fn describe_policy(policy: &RetentionPolicy) -> String {
    let age = match policy.keep_for {
        Some(d) => format!(", and anything newer than {}", humanize(d)),
        None => String::new(),
    };
    format!(
        "keeping at least the {} newest rollback target(s), at most {} record(s){age}",
        policy.keep_min,
        policy.keep_max.max(policy.keep_min)
    )
}

/// Format the timestamp used by retention to evaluate `record` (`deployed_at`,
/// `failed_at`, or `created_at`).
pub(super) fn judged_by(record: &Record) -> String {
    if let Some(at) = record.deployed_at.as_deref().filter(|at| !at.is_empty()) {
        at.to_string()
    } else if let Some(at) = &record.failed_at {
        format!("failed {at}")
    } else if let Some(at) = record.created_at {
        format!("created {}", at.to_rfc3339())
    } else {
        "no timestamp".to_string()
    }
}

/// Format `reason` for display in the retirement plan.
pub(super) fn describe_reason(reason: &RetireReason) -> String {
    match reason {
        RetireReason::BeyondMax(n) => format!("beyond the {n} newest"),
        RetireReason::OlderThan(d) => format!("older than {}", humanize(*d)),
        RetireReason::UnknownAge => "age unknown".to_string(),
    }
}

/// Format `d` using the largest unit (`d`, `h`, `m`, or `s`) that divides it evenly.
pub(super) fn humanize(d: chrono::Duration) -> String {
    let secs = d.num_seconds();
    if secs > 0 && secs % 86_400 == 0 {
        format!("{}d", secs / 86_400)
    } else if secs > 0 && secs % 3_600 == 0 {
        format!("{}h", secs / 3_600)
    } else if secs > 0 && secs % 60 == 0 {
        format!("{}m", secs / 60)
    } else {
        format!("{secs}s")
    }
}

/// Print the Activation records scheduled for retirement and the count kept.
pub(super) fn print_record_plan(retirement: &RecordRetirement, policy: &RetentionPolicy) {
    let plan = &retirement.plan;
    if plan.retire.is_empty() {
        println!("  {}", output::dim(&retirement.kept_note()));
        return;
    }
    println!();
    println!(
        "{} {} deployment record(s), {}:",
        output::bold("Retire:"),
        plan.retire.len(),
        describe_policy(policy),
    );
    for retired in &plan.retire {
        let when = judged_by(&retired.record);
        println!(
            "  {} {} {}",
            output::red("-"),
            retired.record.name,
            output::dim(&format!("({when}; {})", describe_reason(&retired.reason)))
        );
    }
    println!(
        "  {}",
        output::dim(&format!(
            "{} deployment record(s) kept. Kix cannot roll back to a retired deployment \
             record, and the next deploy removes it from tracking annotations on every object.",
            plan.kept.len(),
        ))
    );
}

/// Print the final GC summary line, and stop with exit code 1 if `failed > 0`.
pub(super) fn finish(
    cluster: &str,
    deleted: usize,
    failed: usize,
    records: Option<(usize, usize)>,
) -> Result<()> {
    crate::say!();
    let records_note = match records {
        Some((retired, kept)) if retired > 0 || kept > 0 => {
            format!(", {retired} deployment record(s) retired ({kept} kept)")
        }
        _ => String::new(),
    };
    let deleted = output::green(&deleted.to_string()).into_owned();
    if failed == 0 {
        crate::say!("GC complete for '{cluster}': {deleted} deleted, 0 failed{records_note}");
        return Ok(());
    }
    // A failure is printed even under `-q`, since the command exits 1.
    println!(
        "GC failed for '{cluster}': {deleted} deleted, {} failed{records_note}",
        output::red(&failed.to_string())
    );
    println!("  Resolve the deletion failure(s) listed above and run `kix gc {cluster}` again.");
    Err(Stopped(Exit::Failure).into())
}

/// Build the confirmation prompt for deleting `resources` resources and
/// `records` Activation records.
pub(super) fn deletion_prompt(resources: usize, records: usize) -> String {
    match (resources, records) {
        (0, r) => format!("Delete {r} deployment record(s)? [y/N] "),
        (n, 0) => format!("Delete {n} object(s)? [y/N] "),
        (n, r) => format!("Delete {n} object(s) and {r} deployment record(s)? [y/N] "),
    }
}

/// Prompt the user for confirmation unless `--yes` is set, stopping with exit
/// code 1 on a non-interactive terminal without `--yes`.
pub(super) fn confirm(args: &GcArgs, prompt: &str) -> Result<bool> {
    if args.dry_run {
        println!("\nDry run: nothing was deleted from the cluster.");
        return Ok(false);
    }
    if args.yes {
        return Ok(true);
    }
    if !output::is_interactive() {
        return Err(output::refuse_unconfirmed(
            output::Unconfirmed::GarbageCollect,
            &args.cluster,
        ));
    }
    print!("\n{prompt}");
    std::io::stdout().flush().into_diagnostic()?;
    let mut input = String::new();
    std::io::stdin().read_line(&mut input).into_diagnostic()?;
    let input = input.trim().to_lowercase();
    if input != "y" && input != "yes" {
        println!("GC cancelled. Nothing was deleted from the cluster.");
        return Ok(false);
    }
    Ok(true)
}
