//! Progress and warning output for cluster planning.

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
                "  Objects that exist only in {activation} are not deleted by this rollback; the new deployment record keeps {activation} listed for cleanup, so a later `kix deploy {cluster} --prune` or `kix gc {cluster}` on a machine that has {activation}'s build (or `kix gc --hard {cluster}` from any machine) will remove them."
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
                "  Objects that exist only in {activation} are not deleted by this rollback and nothing names {activation} afterwards; run `kix gc --hard {cluster}` after the rollback to find and remove them."
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
                "  Objects that exist only in {current} are not deleted by this rollback; the new deployment record keeps {current} listed for cleanup, so a later `kix deploy {cluster} --prune` or `kix gc {cluster}` on a machine that has {current}'s build (or `kix gc --hard {cluster}` from any machine) will remove them."
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
        PlanEvent::Connecting => crate::say!("Connecting to cluster..."),
        PlanEvent::NoCachedBuild => crate::say!("No previous activation. First deploy."),
        PlanEvent::LoadingCache => crate::say!("Loading previous activation from cache..."),
        PlanEvent::NoActiveRecord => {
            crate::say!("No previous activation on cluster. First deploy.")
        }
        PlanEvent::Active {
            name,
            identity_hash,
        } => crate::say!(
            "Active activation: {} ({}...)",
            output::bold(name),
            short(identity_hash),
        ),
        PlanEvent::ReadingLive { error: Some(e) } => crate::say!(
            "  {} {e}. Reconstructing previous state from cluster",
            output::yellow("!"),
        ),
        PlanEvent::ReadingLive { error: None } => crate::say!(
            "  {} store path for activation not found locally. Reconstructing previous state from cluster",
            output::yellow("!"),
        ),
        PlanEvent::OlderBuildsLeftOut(count) => crate::say!(
            "  {} {count} objects of this Kix cluster name only older builds, so this plan leaves them; `kix gc --hard` finds them",
            output::dim("note:"),
        ),
        PlanEvent::DeployInFlight(record) => {
            let name = &record.name;
            match record.created_at {
                Some(started) => warning(&format!(
                    "deployment record {} is still in phase Deploying (started at {}).",
                    output::bold(name),
                    started.to_rfc3339(),
                )),
                None => warning(&format!(
                    "deployment record {} is still in phase Deploying.",
                    output::bold(name)
                )),
            }
            crate::esay!(
                "  Either another deploy is running now, or an earlier deploy was killed before it could mark {name} Failed; while {name} stays Deploying, this plan leaves out objects from earlier failed deployments, and completing a new deploy will not clear {name}."
            );
            crate::esay!(
                "  If no deploy is running, mark {name} Failed and run the command again:"
            );
            crate::esay!(
                "    kubectl patch {}/{name} --subresource=status --type=merge -p '{{\"status\":{{\"phase\":\"Failed\",\"failure\":{{\"reason\":\"abandoned\"}}}}}}'",
                keys::ACTIVATIONS_CRD,
            );
        }
        PlanEvent::FailedFolded(record) => {
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
                "  To clean up those objects, run from a machine that has the builds or run `kix gc --hard {cluster}`."
            );
            crate::esay!(
                "  `kix gc --hard` does not clear failed deployment records; to stop this warning after cleaning up, mark each record Superseded:"
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
        PlanEvent::KeptUnresolved { sources, cluster } => {
            let names = some_names(sources.iter().map(|s| s.activation.as_str()));
            warning(&format!(
                "{} earlier deployment(s) ({names}) kept orphaned objects (deployed without `--prune`) from builds that are not in Kix's local store on this machine.",
                sources.len()
            ));
            crate::esay!("  This plan cannot list or delete those orphaned objects.");
            crate::esay!(
                "  To remove them, run `kix deploy {cluster} --prune` from a machine that has those builds, or run `kix gc --hard {cluster}`."
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
