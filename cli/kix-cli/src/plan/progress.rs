//! What the planner reports as it reads the cluster and this machine's
//! builds, as the commands that plan print it.

use kix::manifest::keys;
use kix::plan::PlanEvent;

use crate::output;

/// Print `event`. Under `quiet` only a build that was found and will not
/// load is reported: a plan made without it must show why.
pub fn print(event: PlanEvent<'_>, quiet: bool) {
    match event {
        PlanEvent::FailedBuildUnusable { activation, error } => unusable_build(
            activation,
            error,
            "This plan leaves out what that failed deployment applied.",
        ),
        PlanEvent::ActiveBuildUnusable { activation, error } => {
            unusable_build(activation, error, NO_CURRENT_BUILD)
        }
        PlanEvent::ActiveUnresolved { record } => eprintln!(
            "{} cannot read the build of the current deployment {} on this machine. {NO_CURRENT_BUILD}",
            output::yellow("warning:"),
            output::bold(&record.name),
        ),
        PlanEvent::KeptBuildUnusable { activation, error } => unusable_build(
            activation,
            error,
            "This plan cannot list or delete the orphans an earlier deploy kept from it.",
        ),
        _ if quiet => {}
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
            let since = record
                .created_at
                .map(|t| format!(", started {}", t.to_rfc3339()))
                .unwrap_or_default();
            eprintln!(
                "{} activation {}{since} is still marked as deploying, so this plan leaves \
                 resources from incomplete deployments unchanged.",
                output::yellow("note:"),
                output::bold(&record.name),
            );
            eprintln!(
                "  If that deployment is still running, let it finish. If its process has stopped, mark the"
            );
            eprintln!(
                "  record as failed and rerun this command so Kix can account for its resources:"
            );
            eprintln!(
                "    kubectl patch {}/{} --subresource=status --type=merge \\",
                keys::ACTIVATIONS_CRD,
                record.name,
            );
            eprintln!(
                "      -p '{{\"status\":{{\"phase\":\"Failed\",\"failure\":{{\"reason\":\"abandoned\"}}}}}}'"
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
        PlanEvent::FailedUnresolved { record, cluster } => {
            eprintln!(
                "{} cannot read the build for failed deployment {} on this machine. It may have left resources on the cluster.",
                output::yellow("warning:"),
                output::bold(&record.name),
            );
            eprintln!(
                "  Kix cannot determine which resources it applied, so this plan will not clean them up. Deploy from \
                 the machine that built it, or review and remove unused resources with `kix gc --hard {cluster}` and \
                 then mark the failed record as superseded (hard GC does not update it):"
            );
            eprintln!(
                "    kubectl patch {}/{} --subresource=status --type=merge \
                 -p '{{\"status\":{{\"phase\":\"Superseded\"}}}}'",
                keys::ACTIVATIONS_CRD,
                record.name,
            );
        }
        PlanEvent::KeptFolded(sources) => {
            let names: Vec<&str> = sources.iter().map(|s| s.activation.as_str()).collect();
            crate::say!(
                "  {} including orphans kept by earlier deploys, from {}",
                output::yellow("!"),
                names.join(", "),
            );
        }
        PlanEvent::KeptUnresolved { source, cluster } => {
            eprintln!(
                "{} cannot read the build of activation {} on this machine. An earlier deploy kept orphans from it.",
                output::yellow("warning:"),
                output::bold(&source.activation),
            );
            eprintln!(
                "  This plan cannot list or delete them. Deploy from the machine that built it, or \
                 remove them with `kix gc --hard {cluster}`."
            );
        }
    }
}

/// Say that the build of `activation` was found but will not load, and what
/// the plan does without it.
/// What a rollback does without its current build.
const NO_CURRENT_BUILD: &str = "This rollback compares with no current build: it applies every \
    object of the target and deletes only what failed and kept deploys left. The target's \
    record keeps naming the current build, so a later prune that can read it removes its objects.";

fn unusable_build(activation: &str, error: &str, without_it: &str) {
    eprintln!(
        "{} cannot use the build of activation {}: {error}. {without_it}",
        output::yellow("warning:"),
        output::bold(activation),
    );
}

fn short(hash: &str) -> &str {
    &hash[..8.min(hash.len())]
}
