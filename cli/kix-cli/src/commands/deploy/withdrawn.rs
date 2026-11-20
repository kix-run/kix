//! Refuse to write to a cluster with a Kix that was withdrawn
//! ([`kix::release::trust`]), and warn when a command that only reads runs
//! with one.

use kix::release::index::Withdrawn;
use kix::release::trust::{self, ALLOW_WITHDRAWN_VAR, Verdict};
use kix::version::Version;

use super::stops::Writer;
use crate::exit::{Exit, Stopped};

/// Refuse the deploy or rollback of `cluster` when the running Kix was
/// withdrawn, unless [`ALLOW_WITHDRAWN_VAR`] names it. Fetch the release
/// index first when the kept copy is more than a day old. Return the version
/// to note on the record when the variable let the write through.
pub(crate) fn check(cluster: &str, writer: Writer) -> miette::Result<Option<Version>> {
    let running = kix::version::running();
    let allow = std::env::var(ALLOW_WITHDRAWN_VAR).ok();
    match trust::judge(trust::withdrawal(running, true), allow.as_deref()) {
        Verdict::Current => Ok(None),
        Verdict::Allowed(w) => {
            eprint!("{}", render_allowed(cluster, &w, writer));
            Ok(Some(w.version))
        }
        Verdict::Refused(w) => {
            eprint!("{}", render_refusal(cluster, &w, writer));
            Err(Stopped(Exit::Failure).into())
        }
    }
}

/// Warn when the running Kix was withdrawn. Read only the kept release index,
/// so a command that does not write makes no network request.
pub(crate) fn warn() {
    if let Some(w) = trust::withdrawal(kix::version::running(), false) {
        eprint!("{}", render_warning(&w));
    }
}

fn reason(w: &Withdrawn) -> String {
    format!(
        "Kix {} was withdrawn: {}",
        w.version.release(),
        w.reason.trim_end_matches('.')
    )
}

fn move_to(w: &Withdrawn) -> String {
    match &w.use_instead {
        Some(next) => format!(
            "move this project to Kix {next} with `kix upgrade --to {next}`",
            next = next.release()
        ),
        None => "move this project to another Kix release with `kix upgrade`".to_string(),
    }
}

fn render_refusal(cluster: &str, w: &Withdrawn, writer: Writer) -> String {
    let (blocked, command, verb) = match writer {
        Writer::Deploy => ("Deploy blocked", "deploy", "deploy"),
        Writer::Rollback => ("Rollback blocked", "rollback", "roll back"),
    };
    let version = w.version.release();
    format!(
        "{blocked}: {}.\n\
         Nothing was applied to cluster {cluster}.\n\
         \n\
         Next: {}, then run `kix {command} {cluster}` again.\n\
         To {verb} with Kix {version} anyway, set {ALLOW_WITHDRAWN_VAR}={version}. The record of cluster {cluster} will then show that Kix {version} wrote it.\n",
        reason(w),
        move_to(w),
    )
}

fn render_allowed(cluster: &str, w: &Withdrawn, writer: Writer) -> String {
    let what = match writer {
        Writer::Deploy => "deploy",
        Writer::Rollback => "rollback",
    };
    let version = w.version.release();
    format!(
        "warning: {}.\n\
         {ALLOW_WITHDRAWN_VAR}={version} is set, so this {what} goes ahead, and the record of cluster {cluster} will show that Kix {version} wrote it.\n",
        reason(w),
    )
}

fn render_warning(w: &Withdrawn) -> String {
    format!(
        "warning: {}.\n\
         `kix deploy` and `kix rollback` refuse to run with Kix {}. Next: {}.\n",
        reason(w),
        w.version.release(),
        move_to(w),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn withdrawn(use_instead: Option<&str>) -> Withdrawn {
        Withdrawn {
            version: "0.10.1".parse().unwrap(),
            reason: "it deletes Secrets on rollback.".to_string(),
            use_instead: use_instead.map(|v| v.parse().unwrap()),
            release: None,
        }
    }

    #[test]
    fn a_deploy_refusal_names_the_reason_and_the_ways_on() {
        assert_eq!(
            render_refusal("lt1", &withdrawn(Some("0.10.2")), Writer::Deploy),
            "Deploy blocked: Kix 0.10.1 was withdrawn: it deletes Secrets on rollback.\n\
             Nothing was applied to cluster lt1.\n\
             \n\
             Next: move this project to Kix 0.10.2 with `kix upgrade --to 0.10.2`, then run `kix deploy lt1` again.\n\
             To deploy with Kix 0.10.1 anyway, set KIX_ALLOW_WITHDRAWN=0.10.1. The record of cluster lt1 will then show that Kix 0.10.1 wrote it.\n"
        );
    }

    #[test]
    fn a_rollback_refusal_without_a_replacement_points_at_upgrade() {
        let text = render_refusal("lt1", &withdrawn(None), Writer::Rollback);
        assert!(text.starts_with("Rollback blocked: Kix 0.10.1"), "{text}");
        assert!(
            text.contains("Next: move this project to another Kix release with `kix upgrade`, then run `kix rollback lt1` again."),
            "{text}"
        );
        assert!(
            text.contains("To roll back with Kix 0.10.1 anyway"),
            "{text}"
        );
    }

    #[test]
    fn an_allowed_write_and_a_read_say_what_happens() {
        assert_eq!(
            render_allowed("lt1", &withdrawn(Some("0.10.2")), Writer::Deploy),
            "warning: Kix 0.10.1 was withdrawn: it deletes Secrets on rollback.\n\
             KIX_ALLOW_WITHDRAWN=0.10.1 is set, so this deploy goes ahead, and the record of cluster lt1 will show that Kix 0.10.1 wrote it.\n"
        );
        assert_eq!(
            render_warning(&withdrawn(Some("0.10.2"))),
            "warning: Kix 0.10.1 was withdrawn: it deletes Secrets on rollback.\n\
             `kix deploy` and `kix rollback` refuse to run with Kix 0.10.1. Next: move this project to Kix 0.10.2 with `kix upgrade --to 0.10.2`.\n"
        );
    }
}
