//! Print the refusal of a command whose Kix may not deploy the cluster
//! ([`kix::cluster::stops`]): it would skip a required stop, or a newer
//! minor of Kix made the last deploy.

use kix::cluster::activation::Record;
use kix::cluster::stops::{self, ALLOW_DOWNGRADE_VAR, OlderKix, Refusal, SkippedStop};
use kix::version::Version;

use crate::exit::{Exit, Stopped};
use crate::output;

/// The command that would write the deploy.
#[derive(Clone, Copy)]
pub(crate) enum Writer {
    Deploy,
    Rollback,
}

/// Refuse the deploy or rollback of `cluster`, whose Active record is
/// `active`, when this Kix may not deploy it. Print why and stop with exit
/// code 1. When [`ALLOW_DOWNGRADE_VAR`] lets an older minor through, warn
/// and return the newer version to note on the record.
pub(crate) fn check(
    cluster: &str,
    active: Option<&Record>,
    writer: Writer,
) -> miette::Result<Option<Version>> {
    let running = kix::version::running();
    let Err(refusal) = stops::check(active, running, &stops::required_stops()) else {
        return Ok(None);
    };
    let text = match &*refusal {
        Refusal::SkippedStop(r) => render_skipped_stop(cluster, r, writer),
        Refusal::OlderKix(r)
            if stops::downgrade_allowed(r, std::env::var(ALLOW_DOWNGRADE_VAR).ok().as_deref()) =>
        {
            eprint!("{}", render_downgrade_allowed(cluster, r, writer));
            return Ok(Some(r.last.clone()));
        }
        Refusal::OlderKix(r) => render_older_kix(cluster, r, writer),
    };
    eprint!("{text}");
    Err(Stopped(Exit::Failure).into())
}

/// Refuse a deploy planned from the cache (`--offline`) the way [`check`]
/// does. The plan is already made, so [`ALLOW_DOWNGRADE_VAR`] cannot note
/// itself on the record, and it does not let a downgrade through here.
pub(crate) fn check_offline(cluster: &str, active: Option<&Record>) -> miette::Result<()> {
    let running = kix::version::running();
    let Err(refusal) = stops::check(active, running, &stops::required_stops()) else {
        return Ok(());
    };
    let mut text = match &*refusal {
        Refusal::SkippedStop(r) => render_skipped_stop(cluster, r, Writer::Deploy),
        Refusal::OlderKix(r) => render_older_kix(cluster, r, Writer::Deploy),
    };
    if std::env::var_os(ALLOW_DOWNGRADE_VAR).is_some() {
        text.push_str(&format!(
            "{ALLOW_DOWNGRADE_VAR} does not work with `--offline`. Run `kix deploy {cluster}` without `--offline`.\n"
        ));
    }
    eprint!("{text}");
    Err(Stopped(Exit::Failure).into())
}

/// Warn, for a command that only plans, that `kix deploy` would refuse
/// `cluster` because a newer minor of Kix made its last deploy.
pub(crate) fn warn(cluster: &str, active: Option<&Record>) {
    if let Some(refusal) = stops::older_kix(active, kix::version::running()) {
        eprint!(
            "{} {}",
            output::yellow("warning:"),
            render_older_kix_warning(cluster, &refusal)
        );
    }
}

fn render_skipped_stop(cluster: &str, refusal: &SkippedStop, writer: Writer) -> String {
    let last = refusal.last.release();
    let stop = refusal.stop.release();
    let stop_minor = refusal.stop.minor_text();
    let running = refusal.running.release();
    let (blocked, next) = match writer {
        Writer::Deploy => (
            "Deploy blocked",
            format!(
                "Next: check out the commit where this project was pinned to Kix {stop_minor}.x (for example with `git worktree add` or `git checkout`), run `kix deploy {cluster}` from there, then return here and run `kix deploy {cluster}` again."
            ),
        ),
        Writer::Rollback => (
            "Rollback blocked",
            format!(
                "Next: check out the commit where this project was pinned to Kix {stop_minor}.x (for example with `git worktree add` or `git checkout`), and run `kix rollback {cluster}` from there."
            ),
        ),
    };
    format!(
        "{blocked}: cluster {cluster} was last deployed with Kix {last}, and cannot skip required stop Kix {stop} on the way to Kix {running}.\n\
         Nothing was applied to cluster {cluster}.\n\
         \n\
         Every cluster deployed with Kix older than {stop} must be deployed once with Kix {stop_minor}.x before deploying Kix {running}.\n\
         \n\
         {next}\n"
    )
}

fn render_older_kix(cluster: &str, refusal: &OlderKix, writer: Writer) -> String {
    let last = refusal.last_deploy();
    let minor = refusal.last.minor_text();
    let running = refusal.running.release();
    let (blocked, next) = match writer {
        Writer::Deploy => (
            "Deploy blocked",
            format!(
                "Next: switch to a commit that uses Kix {minor} or newer, or upgrade this project to Kix {minor} or newer with `kix upgrade`. Then run `kix deploy {cluster}` again."
            ),
        ),
        Writer::Rollback => (
            "Rollback blocked",
            format!(
                "Next: run `kix rollback {cluster}` from a commit that uses Kix {minor} or newer."
            ),
        ),
    };
    let verb = match writer {
        Writer::Deploy => "deploy",
        Writer::Rollback => "roll back",
    };
    let newer = refusal.last.release();
    format!(
        "{blocked}: cluster {cluster} was last deployed with {last}, and this is Kix {running}.\n\
         Nothing was applied to cluster {cluster}.\n\
         \n\
         Kix {running} may not understand what Kix {newer} wrote to the cluster. Once Kix {minor} has deployed a cluster, only Kix {minor} or newer can deploy or roll it back.\n\
         \n\
         {next}\n\
         To {verb} with Kix {running} anyway (for example, to downgrade from a broken release), set {ALLOW_DOWNGRADE_VAR}={newer}. Cluster {cluster}'s deployment record will note the downgrade from Kix {newer}.\n"
    )
}

fn render_downgrade_allowed(cluster: &str, refusal: &OlderKix, writer: Writer) -> String {
    let what = match writer {
        Writer::Deploy => "deploy",
        Writer::Rollback => "rollback",
    };
    format!(
        "warning: cluster {cluster} was last deployed with {last}, and this is Kix {running}.\n\
         {ALLOW_DOWNGRADE_VAR}={newer} is set, so this {what} can proceed. Cluster {cluster}'s deployment record will note the downgrade from Kix {newer}.\n",
        last = refusal.last_deploy(),
        running = refusal.running.release(),
        newer = refusal.last.release(),
    )
}

fn render_older_kix_warning(cluster: &str, refusal: &OlderKix) -> String {
    let last = refusal.last_deploy();
    let minor = refusal.last.minor_text();
    let running = refusal.running.release();
    format!(
        "cluster {cluster} was last deployed with {last}, and this is Kix {running}.\n\
         Showing the plan anyway, but `kix deploy` and `kix rollback` will refuse to change cluster {cluster} with Kix {running}.\n\
         Switch to a commit that uses Kix {minor} or newer, or upgrade this project to Kix {minor} or newer with `kix upgrade`.\n"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn refusal() -> SkippedStop {
        SkippedStop {
            last: "0.10.0".parse().unwrap(),
            stop: "0.11.0".parse().unwrap(),
            running: "0.12.1".parse().unwrap(),
        }
    }

    fn older(commit: Option<&str>) -> OlderKix {
        OlderKix {
            last: "0.9.1".parse().unwrap(),
            commit: commit.map(str::to_string),
            running: "0.8.4".parse().unwrap(),
        }
    }

    #[test]
    fn a_deploy_refusal_names_the_stop_and_the_way_through() {
        assert_eq!(
            render_skipped_stop("lt1", &refusal(), Writer::Deploy),
            "Deploy blocked: cluster lt1 was last deployed with Kix 0.10.0, and cannot skip required stop Kix 0.11.0 on the way to Kix 0.12.1.\n\
             Nothing was applied to cluster lt1.\n\
             \n\
             Every cluster deployed with Kix older than 0.11.0 must be deployed once with Kix 0.11.x before deploying Kix 0.12.1.\n\
             \n\
             Next: check out the commit where this project was pinned to Kix 0.11.x (for example with `git worktree add` or `git checkout`), run `kix deploy lt1` from there, then return here and run `kix deploy lt1` again.\n"
        );
    }

    #[test]
    fn a_rollback_refusal_rolls_back_with_the_stop() {
        let text = render_skipped_stop("lt1", &refusal(), Writer::Rollback);
        assert!(text.starts_with("Rollback blocked: cluster lt1"), "{text}");
        assert!(
            text.contains("and run `kix rollback lt1` from there."),
            "{text}"
        );
    }

    #[test]
    fn a_deploy_by_an_older_kix_names_both_versions_and_the_commit() {
        assert_eq!(
            render_older_kix("prod", &older(Some("abc1234def5678")), Writer::Deploy),
            "Deploy blocked: cluster prod was last deployed with Kix 0.9.1 (from commit abc1234), and this is Kix 0.8.4.\n\
             Nothing was applied to cluster prod.\n\
             \n\
             Kix 0.8.4 may not understand what Kix 0.9.1 wrote to the cluster. Once Kix 0.9 has deployed a cluster, only Kix 0.9 or newer can deploy or roll it back.\n\
             \n\
             Next: switch to a commit that uses Kix 0.9 or newer, or upgrade this project to Kix 0.9 or newer with `kix upgrade`. Then run `kix deploy prod` again.\n\
             To deploy with Kix 0.8.4 anyway (for example, to downgrade from a broken release), set KIX_ALLOW_DOWNGRADE=0.9.1. Cluster prod's deployment record will note the downgrade from Kix 0.9.1.\n"
        );
    }

    #[test]
    fn a_rollback_by_an_older_kix_rolls_back_with_the_newer_one() {
        assert_eq!(
            render_older_kix("prod", &older(None), Writer::Rollback),
            "Rollback blocked: cluster prod was last deployed with Kix 0.9.1, and this is Kix 0.8.4.\n\
             Nothing was applied to cluster prod.\n\
             \n\
             Kix 0.8.4 may not understand what Kix 0.9.1 wrote to the cluster. Once Kix 0.9 has deployed a cluster, only Kix 0.9 or newer can deploy or roll it back.\n\
             \n\
             Next: run `kix rollback prod` from a commit that uses Kix 0.9 or newer.\n\
             To roll back with Kix 0.8.4 anyway (for example, to downgrade from a broken release), set KIX_ALLOW_DOWNGRADE=0.9.1. Cluster prod's deployment record will note the downgrade from Kix 0.9.1.\n"
        );
    }

    #[test]
    fn an_allowed_downgrade_says_what_happens() {
        assert_eq!(
            render_downgrade_allowed("prod", &older(Some("abc1234def5678")), Writer::Deploy),
            "warning: cluster prod was last deployed with Kix 0.9.1 (from commit abc1234), and this is Kix 0.8.4.\n\
             KIX_ALLOW_DOWNGRADE=0.9.1 is set, so this deploy can proceed. Cluster prod's deployment record will note the downgrade from Kix 0.9.1.\n"
        );
    }

    #[test]
    fn a_plan_by_an_older_kix_warns() {
        assert_eq!(
            render_older_kix_warning("prod", &older(Some("abc1234def5678"))),
            "cluster prod was last deployed with Kix 0.9.1 (from commit abc1234), and this is Kix 0.8.4.\n\
             Showing the plan anyway, but `kix deploy` and `kix rollback` will refuse to change cluster prod with Kix 0.8.4.\n\
             Switch to a commit that uses Kix 0.9 or newer, or upgrade this project to Kix 0.9 or newer with `kix upgrade`.\n"
        );
    }
}
