//! Progress and warning output for cluster planning.

use kix::cluster::binding;
use kix::manifest::keys;
use kix::plan::PlanEvent;

use crate::output;

/// Print a planning `event`. Under `-q`, only the warnings about a build that
/// was found but would not load, and the rollback warnings about the current
/// build, are printed.
pub fn print(event: PlanEvent<'_>) {
    match event {
        PlanEvent::FailedBuildUnusable { activation, error } => {
            warning_always(&format!(
                "earlier failed deployment {}'s build could not be loaded ({error}).",
                output::bold(activation)
            ));
            eprintln!(
                "  This plan leaves out what {activation} applied, so any objects it created that are not in this build remain on the cluster."
            );
        }
        PlanEvent::ActiveBuildUnusable {
            activation,
            error,
            cluster,
        } => {
            warning_always(&format!(
                "current deployment {}'s build could not be used ({error}).",
                output::bold(activation)
            ));
            rollback_rewrites_everything();
            eprintln!(
                "  This rollback leaves objects that exist only in {activation} on the cluster and records {activation} for cleanup. To delete them later, run {} on a machine that has {activation}'s build, or run `kix gc --full-scan {cluster}` from any machine.",
                super::kept_orphans_cleanup(cluster)
            );
        }
        PlanEvent::ActiveWithoutHash {
            activation,
            cluster,
        } => {
            warning_always(&format!(
                "current deployment record {} has no build hash, so Kix cannot look for its build.",
                output::bold(activation)
            ));
            rollback_rewrites_everything();
            eprintln!(
                "  Objects that exist only in {activation} are not deleted by this rollback and nothing names {activation} afterwards; run `kix gc --full-scan {cluster}` after the rollback to find and remove them."
            );
        }
        PlanEvent::ActiveUnresolved { record, cluster } => {
            let current = &record.name;
            warning_always(&format!(
                "current deployment {}'s build is not on this machine.",
                output::bold(current)
            ));
            rollback_rewrites_everything();
            eprintln!(
                "  This rollback leaves objects that exist only in {current} on the cluster and records {current} for cleanup. To delete them later, run {} on a machine that has {current}'s build, or run `kix gc --full-scan {cluster}` from any machine.",
                super::kept_orphans_cleanup(cluster)
            );
        }
        PlanEvent::KeptBuildUnusable { activation, error } => {
            warning_always(&format!(
                "earlier deployment {}'s build (which has kept orphaned objects) could not be loaded ({error}).",
                output::bold(activation)
            ));
            eprintln!(
                "  This plan cannot list or delete the orphaned objects kept from {activation}."
            );
        }
        PlanEvent::Connecting(connection) => crate::say!("{}", connection.connecting()),
        PlanEvent::Unbound {
            cluster,
            connection,
            uid,
        } => crate::say!(
            "{} {}",
            output::dim("Note:"),
            binding::unbound_note(cluster, connection, uid),
        ),
        PlanEvent::NoCachedBuild => {
            crate::say!("No previous deployment in local cache. First deploy.")
        }
        PlanEvent::LoadingCache => {
            crate::say!("Loading previous deployment from local cache...")
        }
        PlanEvent::NoActiveRecord => {
            crate::say!("No previous deployment record on the cluster. First deploy.")
        }
        PlanEvent::Active {
            name,
            identity_hash,
        } => crate::say!(
            "Current deployment: {} (build {}...)",
            output::bold(name),
            short(identity_hash),
        ),
        PlanEvent::ReadingLive { error: Some(e) } => crate::say!(
            "  {} {e}. Reading live objects from the cluster to compare against.",
            output::yellow("!"),
        ),
        PlanEvent::ReadingLive { error: None } => crate::say!(
            "  {} Local build for current deployment is not on this machine. Reading live objects from the cluster to compare against.",
            output::yellow("!"),
        ),
        PlanEvent::OlderBuildsLeftOut(count) => crate::say!(
            "  {} {count} object(s) of this Kix cluster belong only to older deployments, so this plan leaves them; `kix gc --full-scan` finds and deletes them.",
            output::dim("Note:"),
        ),
        PlanEvent::DeployInFlight(record) => {
            let name = &record.name;
            let since = record
                .created_at
                .map(|t| format!(" (started at {})", t.to_rfc3339()))
                .unwrap_or_default();
            warning(&format!(
                "deployment record {}{since} is still in phase Deploying, and no run holds the deploy lock for it.",
                output::bold(name),
            ));
            crate::esay!(
                "  Either an older version of Kix (which does not use the deploy lock) is deploying now, or an earlier deploy stopped before marking {name} Failed. To avoid deleting resources an active deploy may still be applying, this plan leaves out resources from earlier failed or partial deploys, and a new deploy will not clear {name}."
            );
            crate::esay!(
                "  If no older Kix is deploying this cluster, mark {name} Failed and run the command again:"
            );
            crate::esay!(
                "    kubectl patch {}/{name} --subresource=status --type=merge -p '{{\"status\":{{\"phase\":\"Failed\",\"failure\":{{\"reason\":\"abandoned\"}}}}}}'",
                keys::ACTIVATIONS_CRD,
            );
        }
        PlanEvent::LockHeld(lock) => crate::commands::lock::say_watching(lock),
        PlanEvent::FailedFolded(record) => match record.partly_deployed() {
            Some(partial) => crate::say!(
                "  {} including resources from partial deployment {} ({}...), which applied {}",
                output::yellow("!"),
                output::bold(&record.name),
                short(record.identity_hash.as_deref().unwrap_or_default()),
                partial.only.join(", "),
            ),
            None => {
                crate::say!(
                    "  {} including resources from failed deployment {} ({}...)",
                    output::yellow("!"),
                    output::bold(&record.name),
                    short(record.identity_hash.as_deref().unwrap_or_default()),
                );
                if let Some(reason) = &record.failure_reason {
                    crate::say!("    it stopped because: {reason}");
                }
            }
        },
        PlanEvent::FailedValuesUnknown(record) => crate::say!(
            "    the build of {} is not on this machine. Kix takes in what it applied from its revisions, but the plan cannot tell the values it wrote from drift, so it lists them as drift.",
            record.name,
        ),
        PlanEvent::FailedUnresolved { records, cluster } => {
            let names = some_names(records.iter().map(|r| r.name.as_str()));
            warning(&format!(
                "{} earlier failed deployment(s) ({names}) do not have builds in Kix's local store on this machine.",
                records.len()
            ));
            crate::esay!(
                "  This plan goes ahead, but Kix cannot tell what those failed runs applied, so any objects they created that are not in this build remain on the cluster."
            );
            crate::esay!(
                "  To clean up those objects, run from a machine that has the builds or run `kix gc --full-scan {cluster}`."
            );
            crate::esay!(
                "  `kix gc --full-scan` does not clear failed deployment records; to stop this warning after cleaning up, mark each record Superseded:"
            );
            for record in records {
                crate::esay!(
                    "    kubectl patch {}/{} --subresource=status --type=merge -p '{{\"status\":{{\"phase\":\"Superseded\"}}}}'",
                    keys::ACTIVATIONS_CRD,
                    record.name,
                );
            }
        }
        PlanEvent::KeptFolded(sources) => {
            crate::say!(
                "  {} including orphans kept by earlier deploys, from {}",
                output::yellow("!"),
                some_names(sources.iter().map(|s| s.activation.as_str())),
            );
        }
        PlanEvent::NotHeld(objects) => {
            let names: Vec<String> = objects.iter().map(|rid| rid.display_id()).collect();
            crate::say!(
                "  {} {} object(s) unchanged from the current deployment are missing from the cluster or being deleted, so this plan reapplies them: {}",
                output::yellow("!"),
                objects.len(),
                some_names(names.iter().map(String::as_str)),
            );
        }
        PlanEvent::KindsUnread(kinds) => {
            warning(&format!(
                "this Kubernetes account cannot list {} across the cluster.",
                some_names(kinds.iter().map(String::as_str))
            ));
            crate::esay!(
                "  Without `--reconcile`, this plan skips objects of these kinds that are unchanged from the current deployment, even if they were deleted or are being deleted on the cluster.\n  To check them, grant this account cluster-wide `list` permission for these kinds, or pass `--reconcile` on `kix plan` or `kix deploy` to reapply every resource."
            );
        }
        PlanEvent::KeptUnresolved { sources, cluster } => {
            let names = some_names(sources.iter().map(|s| s.activation.as_str()));
            warning(&format!(
                "{} earlier deployment(s) ({names}) kept orphaned objects (deployed without `--prune`) from builds that are not in Kix's local store on this machine.",
                sources.len()
            ));
            crate::esay!("  This plan cannot list or delete those orphaned objects.");
            crate::esay!(
                "  To remove them, run `kix deploy {cluster} --prune` from a machine that has those builds, or run `kix gc --full-scan {cluster}`."
            );
        }
    }
}

/// Format up to three items from `names`, summarizing any remainder as
/// `and N more`.
fn some_names<'a>(names: impl ExactSizeIterator<Item = &'a str>) -> String {
    const SHOWN: usize = 3;
    let total = names.len();
    let shown: Vec<&str> = names.take(SHOWN).collect();
    let rest = total.saturating_sub(shown.len());
    if rest == 0 {
        shown.join(", ")
    } else {
        format!("{}, and {rest} more", shown.join(", "))
    }
}

/// Print the first line of a warning on stderr unless `-q` is set.
fn warning(first_line: &str) {
    crate::esay!("{} {first_line}", output::yellow("warning:"));
}

/// Print the first line of a warning on stderr, even under `-q`.
fn warning_always(first_line: &str) {
    eprintln!("{} {first_line}", output::yellow("warning:"));
}

/// Print the line every rollback warning about the current build shares.
fn rollback_rewrites_everything() {
    eprintln!(
        "  This rollback writes every object of the target build to the cluster again, and the plan below lists every package as added."
    );
}

fn short(hash: &str) -> &str {
    &hash[..8.min(hash.len())]
}
