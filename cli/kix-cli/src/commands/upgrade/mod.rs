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
mod relocate;
mod route;
mod run;
mod search;
pub mod state;
mod subject;
mod subprocess;
mod target;

use miette::{Result, miette};

use crate::cli::{GlobalArgs, UpgradeArgs};
use crate::exit::Exit;
use acknowledge::acknowledge;
pub use acknowledge::check_deploy;
use choose::{NothingToCompare, check_acknowledged, choose, conclude, pin_only, reset_moved_tag};
use halt::{Flow, Halt, refused};
use kix::flake_lock::INPUT;
use kix::version::Version;
use preview::dry_run;
use relocate::relocate;
use route::plan_route;
use run::{Run, work_dir};
use state::{Status, UpgradeState};
use subject::Subject;
use target::Decision;

/// A build failed.
const EXIT_BUILD_FAILED: Exit = Exit::UpgradeBuildFailed;
/// The upgrade finished, and a person should read what changed.
const EXIT_NEEDS_PERSON: Exit = Exit::UpgradeNeedsPerson;

pub fn run(args: &UpgradeArgs, global: &GlobalArgs) -> Result<Exit> {
    upgrade(args, global).or_else(Halt::end)
}

/// Run `kix upgrade`: work out what the command moves, then move an input
/// to a newer release ([`upgrade_input`]) or a cluster to another input
/// ([`relocate`]).
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
    let subject = Subject::resolve(&dir, args)?;
    let config = kix::project::ProjectConfig::read(Some(&dir), None).map_err(|e| miette!("{e}"))?;
    let previous = UpgradeState::read(&dir).map_err(|e| miette!("{e}"))?;
    // A run that a build failure, a flake.nix edit, or an interruption
    // stopped goes on from where it was.
    let resume = previous
        .clone()
        .filter(|s| matches!(s.status, Status::FixNeeded | Status::EditNeeded));
    if let Some(unfinished) = resume.as_ref().filter(|s| !subject.wrote(s)) {
        let other = subject::command_of(unfinished);
        return Err(refused(format!(
            "Cannot run `{}`: an earlier `{other}` run to Kix {} has not finished (recorded in kix-upgrade.json).\nNo project files were modified.\nNext: run `{other}` to finish that upgrade, or delete kix-upgrade.json to discard its saved state.",
            subject.command(),
            unfinished.to,
        )));
    }
    match &subject {
        Subject::Input { .. } => upgrade_input(
            dir,
            subject,
            args,
            config.upgrade_min_age,
            previous.as_ref(),
            resume.as_ref(),
            verbose,
        ),
        Subject::Cluster { .. } => relocate(
            &dir,
            subject,
            args,
            previous.as_ref(),
            resume.as_ref(),
            verbose,
        ),
    }
}

/// Move an input to a newer release. Each step owns one job: [`choose`]
/// decides the target, [`conclude`] ends a run that does not proceed,
/// [`plan_route`] works out the steps, [`Run::baseline`] builds the
/// clusters as they are, [`Run::walk`] pins and builds each step, and
/// [`Run::finish`] reports what changed.
fn upgrade_input(
    dir: std::path::PathBuf,
    subject: Subject,
    args: &UpgradeArgs,
    min_age: Option<u32>,
    previous: Option<&UpgradeState>,
    resume: Option<&UpgradeState>,
    verbose: bool,
) -> Flow<Exit> {
    let Subject::Input { name, clusters } = subject.clone() else {
        unreachable!("only an input moves to a newer release");
    };
    let command = subject.command();
    // An input that holds clusters back moves to the version `kix` is on,
    // unless the command names another.
    let newest = match name.as_str() {
        INPUT => None,
        _ => subject::release_of(&dir, INPUT)?,
    };
    let to = match (&args.to, name.as_str()) {
        (Some(to), _) => Some(to.clone()),
        (None, INPUT) => None,
        (None, _) if resume.is_some() => None,
        (None, _) => Some(newest.as_ref().map(Version::release).ok_or_else(|| {
            refused(format!(
                "Cannot upgrade input `{name}` without `--to`: `{command}` upgrades `{name}` to match input `kix`, which pins no version of Kix in flake.lock.\nNo project files were modified.\nNext: pass a version with `{command} --to <version>`."
            ))
        })?),
    };
    let chosen = choose(&dir, &name, to.as_deref(), min_age, resume)?;
    if let (Some(newest), Decision::Proceed { target, .. } | Decision::PinOnly(target)) =
        (&newest, &chosen.decision)
        && target > newest
    {
        return Err(refused(format!(
            "Cannot upgrade input `{name}` to Kix {}: input `kix` pins Kix {}, and `kix` must pin the newest version in the project.\nNo project files were modified.\nNext: run `kix upgrade` to upgrade `kix` first.",
            target.release(),
            newest.release()
        )));
    }
    if resume.is_none() && !args.dry_run {
        check_acknowledged(previous, &chosen.decision, &subject.command())?;
    }
    let Decision::Proceed {
        from,
        target,
        requested,
    } = chosen.decision.clone()
    else {
        return conclude(&dir, &name, &command, chosen, args.dry_run);
    };
    // The upgrade builds the baseline with the version the lock pins, so a
    // tag a person moved in flake.nix goes back to it first.
    if resume.is_none() && !args.dry_run {
        reset_moved_tag(&dir, &name)?;
    }
    if clusters.as_ref().is_some_and(Vec::is_empty) {
        pin_only(
            &dir,
            &name,
            &command,
            &target,
            args.dry_run,
            NothingToCompare::NoClusters,
        )?;
        return Ok(Exit::Success);
    }
    let route = plan_route(&chosen, from, target, requested)?;
    if args.dry_run {
        dry_run(&dir, &subject, resume, &route, args, verbose);
        return Ok(Exit::Success);
    }

    let mut run = Run {
        work: work_dir(&dir, &subject),
        subject,
        dir,
        source: chosen.source,
        installed_here: Vec::new(),
        from: route.from.clone(),
        pinned: chosen.pinned.unwrap_or_else(|| route.from.clone()),
        state: None,
        verbose,
    };
    let in_use = run.baseline(resume, &route)?;
    let applying = plan::applying(&route.records, &route.from, &route.goal, in_use.as_ref());
    run.begin(resume, &route, &applying, in_use.as_ref())?;
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
