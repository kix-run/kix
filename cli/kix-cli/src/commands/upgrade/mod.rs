//! `kix upgrade`: move a project to a newer version of Kix.
//!
//! The Kix that runs this command never evaluates the project. Every list
//! and build runs as a subprocess of the installed Kix that matches the
//! project at that step, handed over as `select` does. From another version
//! it reads only the cluster list, the package list, and an exported
//! manifest directory.

mod acknowledge;
mod choose;
mod compare;
mod finish;
mod halt;
mod out;
mod phases;
mod pin;
mod plan;
mod preview;
mod route;
mod run;
mod search;
pub mod state;
mod subprocess;
mod target;

use miette::{Result, miette};

use crate::cli::{GlobalArgs, UpgradeArgs};
use crate::exit::Exit;
use acknowledge::acknowledge;
pub use acknowledge::check_deploy;
use choose::{check_acknowledged, choose, conclude, reset_moved_tag};
use halt::{Flow, Halt, refused};
use preview::dry_run;
use route::plan_route;
use run::{Run, work_dir};
use state::{Status, UpgradeState};
use target::Decision;

/// A build failed.
const EXIT_BUILD_FAILED: Exit = Exit::UpgradeBuildFailed;
/// The upgrade finished, and a person should read what changed.
const EXIT_NEEDS_PERSON: Exit = Exit::UpgradeNeedsPerson;

pub fn run(args: &UpgradeArgs, global: &GlobalArgs) -> Result<Exit> {
    upgrade(args, global).or_else(Halt::end)
}

/// Run `kix upgrade`. Each step owns one job: [`choose`] decides the target,
/// [`conclude`] ends a run that does not proceed, [`plan_route`] works out
/// the steps, [`Run::baseline`] builds the project as it is,
/// [`Run::walk`] pins and builds each step, and [`Run::finish`] reports
/// what changed.
fn upgrade(args: &UpgradeArgs, global: &GlobalArgs) -> Flow<Exit> {
    let verbose = global.verbose > 0;
    let Some(dir) = super::project_dir(&global.flake).filter(|d| d.is_dir()) else {
        return Err(refused(format!(
            "Cannot run `kix upgrade` on non-local flake `{}`: `kix upgrade` must edit flake.nix and flake.lock in a local directory.\nNext: clone the project locally and run `kix upgrade` from that directory.",
            global.flake
        )));
    };
    if !args.acknowledge.is_empty() {
        acknowledge(&dir, &args.acknowledge)?;
        return Ok(Exit::Success);
    }
    let config = kix::project::ProjectConfig::read(Some(&dir), None).map_err(|e| miette!("{e}"))?;
    let previous = UpgradeState::read(&dir).map_err(|e| miette!("{e}"))?;
    // A run that a build failure, a flake.nix edit, or an interruption
    // stopped goes on from where it was.
    let resume = previous
        .clone()
        .filter(|s| matches!(s.status, Status::FixNeeded | Status::EditNeeded));

    let chosen = choose(&dir, args, config.upgrade_min_age, resume.as_ref())?;
    if resume.is_none() && !args.dry_run {
        check_acknowledged(previous.as_ref(), &chosen.decision)?;
    }
    let Decision::Proceed {
        from,
        target,
        requested,
    } = chosen.decision.clone()
    else {
        return conclude(&dir, chosen, args.dry_run);
    };
    // The upgrade builds the baseline with the version the lock pins, so a
    // tag a person moved in flake.nix goes back to it first.
    if resume.is_none() && !args.dry_run {
        reset_moved_tag(&dir)?;
    }
    let route = plan_route(&chosen, from, target, requested)?;
    if args.dry_run {
        dry_run(&dir, resume.as_ref(), &route, args, verbose);
        return Ok(Exit::Success);
    }

    let mut run = Run {
        work: work_dir(&dir),
        dir,
        source: chosen.source,
        installed_here: Vec::new(),
        from: route.from.clone(),
        pinned: chosen.pinned.unwrap_or_else(|| route.from.clone()),
        state: None,
        verbose,
    };
    let in_use = run.baseline(resume.as_ref(), &route)?;
    let applying = plan::applying(&route.records, &route.from, &route.goal, in_use.as_ref());
    run.begin(resume.as_ref(), &route, &applying, in_use.as_ref())?;
    if let Err((failing, failures)) = run.walk(&route)? {
        return Err(run.stopped_at(&route, &failing, &failures, in_use.as_ref()));
    }
    run.finish(&route, &applying)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_refusal_prints_and_ends_with_failure() {
        assert_eq!(refused("No.").end().unwrap(), Exit::Failure);
        assert_eq!(
            Halt::Stopped(EXIT_NEEDS_PERSON).end().unwrap(),
            EXIT_NEEDS_PERSON
        );
        assert!(Halt::from(miette!("broken")).end().is_err());
    }
}
