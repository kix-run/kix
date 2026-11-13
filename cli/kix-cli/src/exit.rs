//! The exit codes of `kix`.
//!
//! An exit code is part of the public API: scripts and CI branch on it, and
//! changing one is a breaking change. Every code the CLI ends with is a
//! variant of [`Exit`], and `main` is the only place that ends the process.
//!
//! A command returns `miette::Result<Exit>`. An `Err` that is not a
//! [`Stopped`] prints its report and exits with [`Exit::Failure`]. A helper
//! deep in a command that has already printed why it stops returns
//! `Err(Stopped(exit).into())`, and `main` exits with that code without
//! printing anything more.

use std::fmt;

/// How `kix` ends. [`Exit::code`] gives the number the process exits with.
///
/// Several variants share a number because commands gave the same number
/// different meanings. Each variant names one meaning.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Exit {
    /// The command did what it was asked, and found nothing to report. Code 0.
    Success,
    /// The command failed, refused to go on, or found a problem. Code 1.
    ///
    /// This covers every error report, a deploy, rollback, or garbage
    /// collection that did not finish cleanly, a confirmation that a
    /// non-interactive run could not give, a failed `kix check`, `kix health`,
    /// `kix drift`, or `kix pin check`, and an upgrade that Kix refused to
    /// start.
    Failure,
    /// The command line could not be parsed. Code 2.
    ///
    /// clap exits with this code itself.
    Usage,
    /// `kix plan` found changes the deploy would make. Code 2.
    PlanHasChanges,
    /// `kix diff` found differences. Code 2.
    DiffHasDifferences,
    /// `kix upgrade` stopped because a build failed, with the current Kix or
    /// at a step, or the library could not be locked at the new tag. Code 2.
    UpgradeBuildFailed,
    /// `kix plan`, or `kix deploy --plan FILE --dry-run`, found that the
    /// deploy would stop: a write the cluster would refuse, or a stateful
    /// migration not accepted with `--accept-migrations`. Code 3.
    PlanWouldStop,
    /// `kix upgrade` finished or stopped, and a person must review what
    /// changed or edit `flake.nix` by hand. Code 3.
    UpgradeNeedsPerson,
    /// `kix deploy --plan FILE` refused because the saved plan no longer
    /// matches what the deploy would do. Code 4.
    StalePlan,
}

impl Exit {
    /// Return the number the process exits with.
    pub fn code(self) -> i32 {
        match self {
            Exit::Success => 0,
            Exit::Failure => 1,
            Exit::Usage
            | Exit::PlanHasChanges
            | Exit::DiffHasDifferences
            | Exit::UpgradeBuildFailed => 2,
            Exit::PlanWouldStop | Exit::UpgradeNeedsPerson => 3,
            Exit::StalePlan => 4,
        }
    }

    /// Return `Exit::Failure` when `failed`, and `Exit::Success` otherwise.
    pub fn failure_if(failed: bool) -> Exit {
        if failed { Exit::Failure } else { Exit::Success }
    }
}

/// A command that returns `()` succeeded.
impl From<()> for Exit {
    fn from((): ()) -> Exit {
        Exit::Success
    }
}

/// An error that ends the command with `.0` after the command has printed
/// why. `main` prints nothing for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stopped(pub Exit);

impl fmt::Display for Stopped {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "stopped with exit code {}", self.0.code())
    }
}

impl std::error::Error for Stopped {}

impl miette::Diagnostic for Stopped {}

/// Return the exit an error report asks for when it is a [`Stopped`].
pub fn stopped(report: &miette::Report) -> Option<Exit> {
    report.downcast_ref::<Stopped>().map(|s| s.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The numbers are a public API. A change here is a breaking change and
    /// needs a change record.
    #[test]
    fn codes_are_stable() {
        let codes = [
            (Exit::Success, 0),
            (Exit::Failure, 1),
            (Exit::Usage, 2),
            (Exit::PlanHasChanges, 2),
            (Exit::DiffHasDifferences, 2),
            (Exit::UpgradeBuildFailed, 2),
            (Exit::PlanWouldStop, 3),
            (Exit::UpgradeNeedsPerson, 3),
            (Exit::StalePlan, 4),
        ];
        for (exit, code) in codes {
            assert_eq!(exit.code(), code, "{exit:?}");
        }
    }

    #[test]
    fn a_stopped_report_carries_its_exit() {
        let report: miette::Report = Stopped(Exit::StalePlan).into();
        assert_eq!(stopped(&report), Some(Exit::StalePlan));
        assert_eq!(stopped(&miette::miette!("boom")), None);
    }
}
