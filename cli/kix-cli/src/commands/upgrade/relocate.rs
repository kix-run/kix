//! Move one cluster to another input: `kix upgrade <cluster> --to <input>`.
//!
//! The move is an upgrade of that one cluster. Kix builds it with the
//! version it is on, lists it under the other input in `[versions]`, builds
//! it again, and reports what changed, as an upgrade of an input does.

use std::path::Path;

use kix::release::{self, Source};
use kix::version::Version;
use miette::miette;

use super::choose::{Chosen, check_acknowledged};
use super::halt::{Flow, refused};
use super::plan;
use super::preview::dry_run;
use super::route::plan_route;
use super::run::{Run, work_dir};
use super::state::UpgradeState;
use super::subject::{Subject, release_of};
use super::target::Decision;
use crate::cli::UpgradeArgs;
use crate::exit::Exit;

/// Move the cluster that `subject` names to its new input.
pub(super) fn relocate(
    dir: &Path,
    subject: Subject,
    args: &UpgradeArgs,
    previous: Option<&UpgradeState>,
    resume: Option<&UpgradeState>,
    verbose: bool,
) -> Flow<Exit> {
    let Subject::Cluster { cluster, from, to } = &subject else {
        unreachable!("only a cluster is moved between inputs");
    };
    if from == to && resume.is_none() {
        println!("The cluster `{cluster}` already uses the input `{to}`. Nothing to move.");
        return Ok(Exit::Success);
    }
    let to_version = release_of(dir, to)?;
    // A stopped run already changed [versions], so the version the cluster
    // came from is the one the run recorded.
    let from_version = match resume {
        Some(s) => Some(
            s.from
                .parse::<Version>()
                .map_err(|_| miette!("kix-upgrade.json names no version in `from`"))?,
        ),
        None => release_of(dir, from)?,
    };
    let (Some(from_version), Some(to_version)) = (from_version, to_version) else {
        return edit_only(
            dir,
            &subject,
            args.dry_run,
            "One of the two inputs pins no release of Kix, so Kix built nothing to compare.",
        );
    };
    if to_version < from_version {
        return Err(refused(format!(
            "Cannot move the cluster `{cluster}` to the input `{to}`: `{to}` pins Kix {}, and the cluster is on Kix {}. `kix upgrade` only moves a cluster to a newer version.\nNo project files were modified.",
            to_version.release(),
            from_version.release()
        )));
    }
    if to_version == from_version {
        return edit_only(
            dir,
            &subject,
            args.dry_run,
            &format!(
                "Both inputs pin Kix {}, so nothing about the cluster changes.",
                to_version.release()
            ),
        );
    }
    let decision = Decision::Proceed {
        from: from_version.clone(),
        target: to_version.clone(),
        requested: to_version.release(),
    };
    if resume.is_none() && !args.dry_run {
        check_acknowledged(previous, &decision)?;
    }
    let source = Source::from_env();
    let index = release::fetch_index(&source).map_err(|e| miette!("{e}"))?;
    let chosen = Chosen {
        decision,
        pinned: Some(from_version.clone()),
        index: Some(index),
        source,
        system: release::system().map_err(|e| miette!("{e}"))?,
        min_age: None,
        today: chrono::Utc::now().date_naive(),
    };
    let mut route = plan_route(
        &chosen,
        from_version.clone(),
        to_version.clone(),
        to_version.release(),
    )?;
    if let Some((stop, _)) = &route.stop {
        return Err(refused(format!(
            "Cannot move the cluster `{cluster}` from Kix {} to Kix {}: Kix {stop} must be deployed to the cluster first.\nNo project files were modified.\nNext: run `kix upgrade {from} --to {stop}`, deploy the clusters on `{from}`, then run `{}` again.",
            from_version.release(),
            to_version.release(),
            subject.command(),
            stop = stop.release()
        )));
    }
    // The cluster goes straight to the version its new input pins. No input
    // pins a version between the two.
    route.steps = vec![route.goal.clone()];
    if args.dry_run {
        dry_run(dir, &subject, resume, &route, args, verbose);
        return Ok(Exit::Success);
    }
    let mut run = Run {
        work: work_dir(dir, &subject),
        dir: dir.to_path_buf(),
        source: chosen.source,
        installed_here: Vec::new(),
        from: from_version.clone(),
        pinned: if from == to { to_version } else { from_version },
        state: None,
        verbose,
        subject,
    };
    let in_use = run.baseline(resume, &route)?;
    let applying = plan::applying(&route.records, &route.from, &route.goal, in_use.as_ref());
    run.begin(resume, &route, &applying, in_use.as_ref())?;
    if let Err((failing, failures)) = run.walk(&route)? {
        return Err(run.stopped_at(&route, &failing, &failures, in_use.as_ref()));
    }
    run.finish(&route, &applying)
}

/// List the cluster under its new input without building, and say `why`
/// there is nothing to compare. With `dry_run`, change nothing.
fn edit_only(dir: &Path, subject: &Subject, dry_run: bool, why: &str) -> Flow<Exit> {
    let Subject::Cluster { cluster, to, .. } = subject else {
        unreachable!("only a cluster is moved between inputs");
    };
    if dry_run {
        println!(
            "`{}` would list the cluster `{cluster}` under `{to}` in kix.toml (dry run, no files changed). {why}",
            subject.command()
        );
        return Ok(Exit::Success);
    }
    kix::versions::move_cluster(dir, cluster, to).map_err(|e| refused(e.to_string()))?;
    println!("Moved the cluster `{cluster}` to the input `{to}` (updated kix.toml). {why}");
    println!("Run `kix plan {cluster}` to see what a deploy would change.");
    Ok(Exit::Success)
}
