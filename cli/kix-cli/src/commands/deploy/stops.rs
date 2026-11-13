//! Print the refusal of a command that would skip a required stop
//! ([`kix::cluster::stops`]).

use kix::cluster::stops::{self, SkippedStop};

/// The command that would write the deploy.
#[derive(Clone, Copy)]
pub(crate) enum Writer {
    Deploy,
    Rollback,
}

/// Refuse the deploy or rollback of `cluster`, whose last deploy Kix `last`
/// made, when it would skip a required stop. Print why and exit 1.
pub(crate) fn check(cluster: &str, last: Option<&str>, writer: Writer) {
    let running = kix::version::running();
    if let Err(refusal) = stops::check(last, running, &stops::required_stops()) {
        eprint!("{}", render(cluster, &refusal, writer));
        std::process::exit(1);
    }
}

fn render(cluster: &str, refusal: &SkippedStop, writer: Writer) -> String {
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

    #[test]
    fn a_deploy_refusal_names_the_stop_and_the_way_through() {
        assert_eq!(
            render("lt1", &refusal(), Writer::Deploy),
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
        let text = render("lt1", &refusal(), Writer::Rollback);
        assert!(text.starts_with("Rollback blocked: cluster lt1"), "{text}");
        assert!(
            text.contains("and run `kix rollback lt1` from there."),
            "{text}"
        );
    }
}
