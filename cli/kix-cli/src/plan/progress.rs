//! What the planner reports as it reads the cluster and this machine's
//! builds, as the commands that plan print it.

use kix::manifest::keys;
use kix::plan::PlanEvent;

use crate::output;

/// Print `event`. Under `-q` only a build that was found and will not
/// load is reported: a plan made without it must show why.
pub fn print(event: PlanEvent<'_>) {
    match event {
        PlanEvent::FailedBuildUnusable { activation, error } => unusable_build(
            activation,
            error,
            "This plan leaves out what that failed deployment applied.",
        ),
        PlanEvent::ActiveBuildUnusable { activation, error } => {
            unusable_build(activation, error, NO_CURRENT_BUILD)
        }
        PlanEvent::ActiveWithoutHash {
            activation,
            cluster,
        } => {
            eprintln!(
                "{} the current deployment {} has no identity hash, so this rollback cannot find its build.",
                output::yellow("warning:"),
                output::bold(activation),
            );
            eprintln!(
                "  This rollback compares with no current build: it applies every object of the \
                 target and deletes only what failed and kept deploys left. Nothing names the \
                 current build afterwards, so remove what it leaves with `kix gc --hard {cluster}`."
            );
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
            crate::esay!(
                "{} activation {}{since} is still marked as deploying, so this plan leaves \
                 resources from incomplete deployments unchanged.",
                output::yellow("note:"),
                output::bold(&record.name),
            );
            crate::esay!(
                "  If that deployment is still running, let it finish. If its process has stopped, mark the"
            );
            crate::esay!(
                "  record as failed and rerun this command so Kix can account for its resources:"
            );
            crate::esay!(
                "    kubectl patch {}/{} --subresource=status --type=merge \\",
                keys::ACTIVATIONS_CRD,
                record.name,
            );
            crate::esay!(
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
        PlanEvent::FailedUnresolved { records, cluster } => {
            let names = some_names(records.iter().map(|r| r.name.as_str()));
            crate::esay!(
                "{} cannot read the {} of {} on this machine: {names}. {} may have left resources on the cluster.",
                output::yellow("warning:"),
                plural(records.len(), "build", "builds"),
                plural(records.len(), "failed deployment", "failed deployments"),
                plural(records.len(), "It", "They"),
            );
            crate::esay!(
                "  Kix cannot tell which resources {} applied, so this plan leaves them. Deploy from a machine \
                 that has the {}, or review and remove unused resources with `kix gc --hard {cluster}` and then \
                 mark each failed record as superseded (hard GC does not update it):",
                plural(records.len(), "it", "they"),
                plural(records.len(), "build", "builds"),
            );
            crate::esay!(
                "    kubectl patch {}/<name> --subresource=status --type=merge \
                 -p '{{\"status\":{{\"phase\":\"Superseded\"}}}}'",
                keys::ACTIVATIONS_CRD,
            );
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
            crate::esay!(
                "{} cannot read the {} of {} on this machine: {names}. Earlier deploys kept orphans from {}.",
                output::yellow("warning:"),
                plural(sources.len(), "build", "builds"),
                plural(sources.len(), "activation", "activations"),
                plural(sources.len(), "it", "them"),
            );
            crate::esay!(
                "  This plan cannot list or delete those orphans. Deploy from a machine that has the {}, or \
                 remove them with `kix gc --hard {cluster}`.",
                plural(sources.len(), "build", "builds"),
            );
        }
    }
}

/// Up to three of `names`, then how many more: a list of forty activations
/// is a count, not a line.
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

fn plural<'a>(count: usize, one: &'a str, many: &'a str) -> &'a str {
    if count == 1 { one } else { many }
}

/// What a rollback does without its current build.
const NO_CURRENT_BUILD: &str = "This rollback compares with no current build: it applies every \
    object of the target and deletes only what failed and kept deploys left. The target's \
    record keeps naming the current build, so a later prune that can read it removes its objects.";

/// Say that the build of `activation` was found but will not load, and what
/// the plan does without it.
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
