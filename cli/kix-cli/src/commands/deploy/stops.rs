//! Print the refusal of a command whose Kix may not deploy the cluster
//! ([`kix::cluster::stops`]): it would skip a required stop, or a newer
//! minor of Kix made the last deploy.

use kix::cluster::activation::Record;
use kix::cluster::stops::{self, OlderKix, Refusal, SkippedStop};

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
/// code 1.
pub(crate) fn check(cluster: &str, active: Option<&Record>, writer: Writer) -> miette::Result<()> {
    let running = kix::version::running();
    if let Err(refusal) = stops::check(active, running, &stops::required_stops()) {
        let text = match &*refusal {
            Refusal::SkippedStop(r) => render_skipped_stop(cluster, r, writer),
            Refusal::OlderKix(r) => render_older_kix(cluster, r, writer),
        };
        eprint!("{text}");
        return Err(Stopped(Exit::Failure).into());
    }
    Ok(())
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
                "Next: make the change on a commit that uses Kix {minor} or newer, or move this project to Kix {minor} or newer with `kix upgrade`. Then run `kix deploy {cluster}` again."
            ),
        ),
        Writer::Rollback => (
            "Rollback blocked",
            format!(
                "Next: run `kix rollback {cluster}` from a commit that uses Kix {minor} or newer."
            ),
        ),
    };
    format!(
        "{blocked}: cluster {cluster} was last deployed with {last}, and this is Kix {running}.\n\
         Nothing was applied to cluster {cluster}.\n\
         \n\
         Once Kix {minor} has deployed a cluster, only Kix {minor} or newer can deploy it.\n\
         \n\
         {next}\n"
    )
}

fn render_older_kix_warning(cluster: &str, refusal: &OlderKix) -> String {
    let last = refusal.last_deploy();
    let minor = refusal.last.minor_text();
    let running = refusal.running.release();
    format!(
        "cluster {cluster} was last deployed with {last}, and this is Kix {running}. `kix deploy {cluster}` with this Kix will refuse to deploy.\n\
         Make the change on a commit that uses Kix {minor} or newer, or move this project to Kix {minor} or newer with `kix upgrade`.\n"
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
             Once Kix 0.9 has deployed a cluster, only Kix 0.9 or newer can deploy it.\n\
             \n\
             Next: make the change on a commit that uses Kix 0.9 or newer, or move this project to Kix 0.9 or newer with `kix upgrade`. Then run `kix deploy prod` again.\n"
        );
    }

    #[test]
    fn a_rollback_by_an_older_kix_rolls_back_with_the_newer_one() {
        assert_eq!(
            render_older_kix("prod", &older(None), Writer::Rollback),
            "Rollback blocked: cluster prod was last deployed with Kix 0.9.1, and this is Kix 0.8.4.\n\
             Nothing was applied to cluster prod.\n\
             \n\
             Once Kix 0.9 has deployed a cluster, only Kix 0.9 or newer can deploy it.\n\
             \n\
             Next: run `kix rollback prod` from a commit that uses Kix 0.9 or newer.\n"
        );
    }

    #[test]
    fn a_plan_by_an_older_kix_warns() {
        assert_eq!(
            render_older_kix_warning("prod", &older(Some("abc1234def5678"))),
            "cluster prod was last deployed with Kix 0.9.1 (from commit abc1234), and this is Kix 0.8.4. `kix deploy prod` with this Kix will refuse to deploy.\n\
             Make the change on a commit that uses Kix 0.9 or newer, or move this project to Kix 0.9 or newer with `kix upgrade`.\n"
        );
    }
}
