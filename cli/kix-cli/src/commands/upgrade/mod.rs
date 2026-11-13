//! `kix upgrade`: move a project to a newer version of Kix.
//!
//! The Kix that runs this command never evaluates the project. Every list
//! and build runs as a subprocess of the installed Kix that matches the
//! project at that step, handed over as `select` does. From another version
//! it reads only the cluster list, the package list, and an exported
//! manifest directory.

mod compare;
mod out;
mod pin;
mod plan;
mod search;
pub mod state;

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

use kix::changes::Kind;
use kix::installs;
use kix::release::{self, Source};
use kix::version::Version;
use kix::version::policy::Requirement;
use miette::{Result, miette};

use crate::cli::{GlobalArgs, UpgradeArgs};
use crate::exit::{Exit, Stopped};
use out::Failed;
use plan::{Applying, ReleaseRecords};
use state::{DataChange, Status, Step, UpgradeState};

/// A build failed.
const EXIT_BUILD_FAILED: Exit = Exit::UpgradeBuildFailed;
/// The upgrade finished, and a person should read what changed.
const EXIT_NEEDS_PERSON: Exit = Exit::UpgradeNeedsPerson;
/// Kix refused to start.
const EXIT_REFUSED: Exit = Exit::Failure;

pub fn run(args: &UpgradeArgs, global: &GlobalArgs) -> Result<()> {
    let verbose = global.verbose > 0;
    let Some(dir) = super::project_dir(&global.flake).filter(|d| d.is_dir()) else {
        return refuse(&format!(
            "Cannot run `kix upgrade` on non-local flake `{}`: `kix upgrade` must edit flake.nix and flake.lock in a local directory.\nNext: clone the project locally and run `kix upgrade` from that directory.",
            global.flake
        ));
    };
    if !args.acknowledge.is_empty() {
        return acknowledge(&dir, &args.acknowledge);
    }
    let config = kix::project::ProjectConfig::read(Some(&dir), None).map_err(|e| miette!("{e}"))?;
    let previous = UpgradeState::read(&dir).map_err(|e| miette!("{e}"))?;

    // A run that a build failure, a flake.nix edit, or an interruption
    // stopped goes on from where it was.
    let resume = previous
        .clone()
        .filter(|s| matches!(s.status, Status::FixNeeded | Status::EditNeeded));
    let from: Option<Version> = match &resume {
        Some(s) => Some(
            s.from
                .parse()
                .map_err(|_| miette!("{} names no version in `from`", state::FILE))?,
        ),
        None => project_version(&dir)?,
    };
    let to = match args.to.as_deref() {
        None | Some("latest") => None,
        Some(text) => match text.parse::<Requirement>() {
            Ok(req) => Some(req),
            Err(_) => {
                return refuse(&format!(
                    "Invalid `--to` value `{text}`: expected a version (such as `0.12.1`), a minor series (such as `0.12`), or `latest`."
                ));
            }
        },
    };
    // The version the project is on already: nothing is upgraded, so the
    // release index is not needed.
    if resume.is_none()
        && let (Some(from), Some(Requirement::Exact(v))) = (&from, &to)
        && v == from
    {
        println!("Already on Kix {}. Nothing to upgrade.", from.release());
        return Ok(());
    }

    if resume.is_none()
        && !args.dry_run
        && let Some(p) = &previous
        && !p.unacknowledged().is_empty()
    {
        let refs: Vec<&str> = p
            .unacknowledged()
            .iter()
            .map(|d| d.reference.as_str())
            .collect();
        let migration = if refs.len() == 1 {
            "an unacknowledged data migration"
        } else {
            "unacknowledged data migrations"
        };
        return refuse(&format!(
            "Cannot start a new upgrade: the previous upgrade to Kix {} has {migration} ({}).\nNo project files were modified.\nNext: review {} in kix-upgrade.json, run `kix upgrade --acknowledge {}`, then run `kix upgrade` again.",
            p.to,
            out::list(&refs),
            out::list(&refs),
            refs.join(" ")
        ));
    }

    // A project that pins no version has nothing to build and compare
    // against, so Kix only pins the version it names exactly.
    if from.is_none()
        && let Some(Requirement::Exact(v)) = &to
    {
        return pin_only(&dir, v, args.dry_run);
    }

    let source = Source::from_env();
    let system = release::system().map_err(|e| miette!("{e}"))?;
    let index = release::fetch_index(&source).map_err(|e| miette!("{e}"))?;
    let releases = plan::usable(&index.releases, &system);
    let min_age = config.upgrade_min_age;
    let today = chrono::Utc::now().date_naive();
    // A prerelease is a target only when `--to` names it in full.
    let prerelease = match &to {
        Some(Requirement::Exact(v)) if v.is_prerelease() => index
            .releases
            .iter()
            .find(|r| r.version == *v && r.systems.contains(&system))
            .map(|r| r.version.clone()),
        _ => None,
    };
    let Some(target) =
        prerelease.or_else(|| plan::choose_target(&releases, to.as_ref(), min_age, today))
    else {
        let newest_age = plan::newest_age(&releases, today).map(|d| {
            format!(
                "newest release is {d} {} old",
                if d == 1 { "day" } else { "days" }
            )
        });
        return refuse(&match (&to, min_age) {
            (Some(to), Some(days)) => format!(
                "No Kix release for {system} matches `--to {to}` and `min-age = \"{days}d\"` in kix.toml{}.\nNext: pass an exact version with `--to`, or lower `min-age` in kix.toml.",
                newest_age.map(|a| format!(" ({a})")).unwrap_or_default()
            ),
            (Some(to), None) => format!(
                "No Kix release for {system} matches `--to {to}`.\nNext: pass an available version or minor series with `--to`, or omit `--to` for the latest release."
            ),
            (None, Some(days)) => format!(
                "No Kix release for {system} is at least {days} days old (`min-age = \"{days}d\"` in kix.toml{}).\nNext: lower `min-age` in kix.toml, or pass an exact version with `--to`.",
                newest_age.map(|a| format!("; {a}")).unwrap_or_default()
            ),
            (None, None) => format!("No Kix release found for {system}."),
        });
    };
    let Some(from) = from else {
        return pin_only(&dir, &target, args.dry_run);
    };
    if target <= from {
        if resume.is_some() {
            return refuse(&format!(
                "Cannot resume upgrade from Kix {from}: target Kix {target} is not newer than {from}.\nNo project files were modified.\nNext: pass a version newer than {from} with `--to`, or delete kix-upgrade.json to start a new upgrade.",
                from = from.release(),
                target = target.release()
            ));
        }
        if to.is_none() && min_age.is_none() {
            println!(
                "Already on the latest Kix release ({}). Nothing to upgrade.",
                from.release()
            );
        } else if let (None, Some(days)) = (&to, min_age) {
            println!(
                "Already on Kix {} (matches target {} for `min-age = \"{days}d\"` in kix.toml). Nothing to upgrade.",
                from.release(),
                target.release()
            );
        } else {
            println!(
                "Already on Kix {} (matches target {}). Nothing to upgrade.",
                from.release(),
                target.release()
            );
        }
        return Ok(());
    }

    let (records, without_notes) = fetch_records(&source, &index.releases, &from, &target)?;
    let stop = plan::required_stop(&releases, &records, &from, &target);
    let goal = stop
        .as_ref()
        .map_or(target.clone(), |(_, until)| until.clone());
    let steps = plan::steps(&releases, &from, &goal);

    let mut run = Run {
        dir: dir.clone(),
        source,
        work: work_dir(&dir),
        installed_here: Vec::new(),
        from: from.clone(),
        pinned: match project_version(&dir) {
            Ok(Some(v)) => v,
            _ => from.clone(),
        },
        state: None,
        verbose,
    };
    let saved_in_use = |s: &UpgradeState| {
        s.packages_in_use
            .as_ref()
            .map(|p| p.iter().cloned().collect::<BTreeSet<String>>())
    };

    if args.dry_run {
        let from_kix = installs::installed()
            .into_iter()
            .find(|i| i.version == from)
            .map(|i| i.bin());
        let (in_use, known) = match (&resume, &from_kix) {
            (Some(s), _) => (
                saved_in_use(s),
                Known::of(s.packages_in_use.is_some(), None),
            ),
            (None, Some(kix)) => {
                let in_use = packages_in_use(kix, &from, &dir);
                let count = clusters(kix, &dir).ok().map(|c| c.len());
                let known = Known::of(in_use.is_some(), count);
                (in_use, known)
            }
            (None, None) => (None, Known::Nothing),
        };
        let applying = plan::applying(&records, &from, &goal, in_use.as_ref());
        preview(&Preview {
            from: &from,
            target: &target,
            steps: &steps,
            stop: stop.as_ref(),
            applying: &applying,
            known,
            without_notes: &without_notes,
            verbose,
            command: &match args.to.as_deref() {
                None | Some("latest") => "kix upgrade".to_string(),
                Some(text) => format!("kix upgrade --to {text}"),
            },
        });
        return Ok(());
    }

    let before = run.work.join("before");
    let in_use = match &resume {
        // After the first pin, the version the upgrade started from can no
        // longer evaluate the project, so it is never asked again.
        Some(s) => {
            if s.before != before || !before.is_dir() {
                return refuse(&format!(
                    "Cannot resume upgrade from Kix {from}: cached baseline builds were not found at {}.\nflake.nix and flake.lock remain at Kix {pinned}.\nNext: delete kix-upgrade.json and run `kix upgrade` to start a new comparison from Kix {pinned}.",
                    before.display(),
                    from = from.release(),
                    pinned = run.pinned.release()
                ));
            }
            // Name the pin only when the project is on a step between the
            // two ends; otherwise the next lines say what Kix does first.
            if run.pinned != from && run.pinned != goal {
                println!(
                    "Resuming upgrade Kix {} -> {} (from {}, reusing {} baseline)",
                    from.release(),
                    goal.release(),
                    run.pinned.release(),
                    from.release()
                );
            } else {
                println!(
                    "Resuming upgrade Kix {} -> {} (reusing {} baseline)",
                    from.release(),
                    goal.release(),
                    from.release()
                );
            }
            println!();
            saved_in_use(s)
        }
        None => {
            println!("Upgrading Kix {} -> {}", from.release(), goal.release());
            if !without_notes.is_empty() {
                println!("{}", out::without_notes_line(&without_notes));
            }
            println!();
            let from_kix = run.kix(&from)?;
            let names = clusters(&from_kix, &dir).map_err(|e| miette!("{e}"))?;
            if names.is_empty() {
                return refuse(&format!(
                    "Cannot upgrade: Kix {} found no clusters in this project.\nNo project files were modified.\nNext: add at least one cluster to the project, then run `kix upgrade` again.",
                    from.release()
                ));
            }
            let in_use = packages_in_use(&from_kix, &from, &dir);
            let built = run.build_all(&from_kix, &from, &before);
            let failed: Vec<String> = built.failures.iter().map(|f| f.cluster.clone()).collect();
            println!(
                "{}",
                out::build_line(
                    built.clusters.len(),
                    &from,
                    true,
                    Some(&built.clusters),
                    (!failed.is_empty()).then_some(Failed::Count(&failed, built.clusters.len())),
                )
            );
            if !failed.is_empty() {
                print_failures(&built.failures);
                println!();
                if failed.len() == 1 {
                    println!(
                        "Cannot start upgrade: cluster {} does not build with your current Kix {}.",
                        failed[0],
                        from.release()
                    );
                } else {
                    println!(
                        "Cannot start upgrade: clusters {} do not build with your current Kix {}.",
                        out::list(&failed),
                        from.release()
                    );
                }
                println!("No project files were modified.");
                println!(
                    "Next: fix the build on Kix {}, then run `kix upgrade` again.",
                    from.release()
                );
                return exit(EXIT_BUILD_FAILED);
            }
            in_use
        }
    };
    let applying = plan::applying(&records, &from, &goal, in_use.as_ref());

    // Written before the first pin and after each step, so a project left
    // pinned part of the way always has a state to resume from.
    run.state = Some(UpgradeState {
        schema: state::SCHEMA.into(),
        from: from.release(),
        to: goal.release(),
        status: Status::FixNeeded,
        steps: resume.as_ref().map(|s| s.steps.clone()).unwrap_or_default(),
        records: by_kind(&applying),
        data_changes: data_changes(&applying),
        acknowledged: resume
            .as_ref()
            .map(|s| s.acknowledged.clone())
            .unwrap_or_default(),
        sensitive_changes: 0,
        cli_hits: Vec::new(),
        before: before.clone(),
        packages_in_use: in_use.as_ref().map(|p| p.iter().cloned().collect()),
    });
    run.save()?;

    let last = run.state().steps.last().cloned();
    let result = match last {
        None => run.jump(&goal, &steps)?,
        Some(last) => {
            let at: Version = last
                .version
                .parse()
                .map_err(|_| miette!("{} names no version in its last step", state::FILE))?;
            let remaining: Vec<Version> = if last.result == "ok" {
                steps.iter().filter(|v| **v > at).cloned().collect()
            } else {
                run.state_mut().steps.pop();
                steps.iter().filter(|v| **v >= at).cloned().collect()
            };
            if remaining.is_empty() || (run.state().steps.is_empty() && at == goal) {
                run.jump(&goal, &steps)?
            } else {
                run.step_through(&remaining)?
            }
        }
    };

    if let Err((failing, failures)) = result {
        print_failures(&failures);
        let previous_step = steps
            .iter()
            .filter(|v| **v < failing)
            .max()
            .unwrap_or(&from);
        let matching: Vec<Applying> =
            plan::applying(&records, previous_step, &failing, in_use.as_ref())
                .into_iter()
                .filter(|a| a.record.kind == Kind::Error)
                .collect();
        print_matching(&matching, previous_step, &failing);
        let position = steps
            .iter()
            .position(|v| *v == failing)
            .map_or(1, |i| i + 1);
        println!();
        if failing != goal {
            println!(
                "Stopped at Kix {} (step {position} of {} toward {}).",
                failing.release(),
                steps.len(),
                goal.release()
            );
            println!(
                "flake.nix and flake.lock are pinned to {} so you can fix this step first.",
                failing.release()
            );
            println!(
                "Next: fix the error above, then run `kix upgrade` to continue to {}.",
                goal.release()
            );
        } else {
            if steps.len() == 1 {
                println!("Stopped at Kix {}.", goal.release());
            } else {
                println!(
                    "Stopped at Kix {} (step {position} of {}).",
                    goal.release(),
                    steps.len()
                );
            }
            println!(
                "flake.nix and flake.lock are pinned to {} so you can fix the build.",
                goal.release()
            );
            println!("Next: fix the error above, then run `kix upgrade` to finish the upgrade.");
        }
        run.state_mut().status = Status::FixNeeded;
        run.save()?;
        run.prune(&from, &failing);
        return exit(EXIT_BUILD_FAILED);
    }
    let mut state = run.state.take().expect("set above");

    let after = run.work.join(goal.release());
    let report = report_changes(&before, &after, &from, &goal)?;
    state.sensitive_changes = report.sensitive;

    let notes = out::notes(&applying, false, &from, &goal);
    if !notes.is_empty() {
        println!();
        println!("Release notes for this upgrade:");
        if let Some(legend) = out::legend(&applying, None) {
            println!("{legend}");
        }
        for line in notes {
            println!("{line}");
        }
    }

    let needles: Vec<String> = applying
        .iter()
        .flat_map(|a| a.record.cli.iter().cloned())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if !needles.is_empty() {
        match search::tracked(&dir) {
            Some(files) => state.cli_hits = search::search(&dir, &files, &needles),
            None => {
                println!();
                println!(
                    "Note: skipped searching project files for changed commands or flags (not a git repository)."
                );
            }
        }
        if !state.cli_hits.is_empty() {
            println!();
            println!("Project files matching changed commands or flags:");
            for hit in &state.cli_hits {
                println!("  {}:{}: {}", hit.file, hit.line, hit.text);
            }
        }
    }

    run.prune(&from, &goal);

    state
        .acknowledged
        .retain(|a| state.data_changes.iter().any(|d| &d.reference == a));
    let mut items = report.review.items();
    for a in plan::of_kind(&applying, Kind::Silent) {
        if !a.record.touches_data {
            items.push(out::silent_item(a));
        } else if !state.acknowledged.contains(&a.reference()) {
            items.push(out::data_item(a));
        }
    }
    let silent = !plan::of_kind(&applying, Kind::Silent).is_empty();
    let needs_person = stop.is_some()
        || report.any_changed
        || report.sensitive > 0
        || silent
        || !state.unacknowledged().is_empty();
    state.status = if stop.is_some() {
        Status::RequiredStop
    } else if needs_person {
        Status::NeedsPerson
    } else {
        Status::Done
    };
    state.write(&dir).map_err(|e| miette!("{e}"))?;

    println!();
    if !needs_person {
        println!("Upgraded to Kix {}. Ready to deploy.", goal.release());
        return Ok(());
    }
    if let Some((r, _)) = &stop {
        items.push(vec![
            format!(
                "Kix {} must be deployed to all clusters before continuing to {}",
                r.release(),
                target.release()
            ),
            format!(
                "     (`kix deploy` on {} will refuse any cluster still on {}).",
                target.release(),
                from.release()
            ),
            format!(
                "     flake.nix and flake.lock are pinned to {}.",
                goal.release()
            ),
        ]);
    }
    println!(
        "Upgraded to Kix {}, but review before deploying:",
        goal.release()
    );
    for line in out::numbered(&items) {
        println!("{line}");
    }
    if stop.is_some() {
        println!(
            "Next: commit this {} step and deploy every cluster with `kix deploy <cluster>`, then run `kix upgrade` to continue to {}.",
            goal.release(),
            target.release()
        );
    }
    exit(EXIT_NEEDS_PERSON)
}

/// Print `text` and exit with [`EXIT_REFUSED`].
fn refuse(text: &str) -> Result<()> {
    println!("{text}");
    exit(EXIT_REFUSED)
}

/// Return the error that ends `kix upgrade` with `code` once it has printed
/// why.
fn exit(code: Exit) -> Result<()> {
    Err(Stopped(code).into())
}

/// Return the version of Kix the project in `dir` uses, from the release
/// tag its `flake.lock` pins, or `None` when it pins none.
fn project_version(dir: &Path) -> Result<Option<Version>> {
    use kix::flake_lock::{Development, LockError, ProjectKix};
    match kix::flake_lock::project_kix(dir, &[]) {
        Ok(ProjectKix::Release(v)) => Ok(Some(v)),
        Ok(ProjectKix::Development(Development::OwnLibrary)) => {
            refuse(
                "This project holds the Kix library itself, so it has no version of Kix to upgrade.",
            )?;
            unreachable!("refuse exits")
        }
        Ok(ProjectKix::Development(_)) => Ok(None),
        Err(e @ LockError::Unreadable { .. }) => {
            refuse(&format!("{e}\nNo project files were modified."))?;
            unreachable!("refuse exits")
        }
        Err(_) => Ok(None),
    }
}

/// Pin the project in `dir`, whose `flake.lock` pins no version of Kix, to
/// `version`. There is no version to build and compare against, so Kix
/// only moves the Kix library. With `dry_run`, change nothing.
fn pin_only(dir: &Path, version: &Version, dry_run: bool) -> Result<()> {
    let release = version.release();
    if dry_run {
        println!(
            "This project's flake.lock pins no version of Kix. `kix upgrade --to {release}` would pin the Kix library to {release} in flake.nix and flake.lock (dry run, no files changed)."
        );
        println!("Next: run `kix upgrade --to {release}`.");
        return Ok(());
    }
    let pinned = pin::prepare(dir, None, version).and_then(|plan| pin::pin(None, version, &plan));
    match pinned {
        Ok(files) if files.is_empty() => {
            println!("flake.nix and flake.lock already pin Kix {release}.");
            Ok(())
        }
        Ok(files) => {
            println!(
                "Pinned the Kix library to {release} (updated {}). This project's flake.lock pinned no version of Kix before, so Kix built nothing to compare.",
                out::list(&files)
            );
            println!("Commit {}.", out::and_list(&files));
            Ok(())
        }
        Err(pin::PinError::Edit(edit)) => refuse(&edit_message(
            &edit,
            "Kix did not change flake.nix or flake.lock.",
            &format!("kix upgrade --to {release}"),
        )),
        Err(e) => refuse(&e.to_string()),
    }
}

/// Return the text of the stop for an edit a person must make in
/// `flake.nix`. `state` says what Kix left as it was, and `command` runs
/// after the edit.
fn edit_message(edit: &kix::pin_library::HandEdit, state: &str, command: &str) -> String {
    let count = match edit.lines.len() {
        2 => "two".to_string(),
        3 => "three".to_string(),
        n => n.to_string(),
    };
    let mut text = format!(
        "Cannot update flake.nix automatically: {count} inputs use the Kix library's repository:\n"
    );
    for (n, line) in &edit.lines {
        text.push_str(&format!("  flake.nix:{n}:   {line}\n"));
    }
    text.push('\n');
    text.push_str(state);
    text.push('\n');
    text.push_str(&format!(
        "Next: change the url of the Kix library input to {} in flake.nix, leave the\nother inputs as they are, then run `{command}` again.",
        edit.to_url
    ));
    text
}

/// Return the directory `kix upgrade` keeps its builds of the project in
/// `dir` in, under Kix's cache directory.
fn work_dir(dir: &Path) -> PathBuf {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(dir.as_os_str().as_encoded_bytes());
    let key: String = digest.iter().take(8).map(|b| format!("{b:02x}")).collect();
    kix::eval::store::default_cache_dir()
        .join("upgrade")
        .join(key)
}

/// Fetch the change records of every release after `from` up to `target`
/// that is not a prerelease, and of `target` itself, whichever systems it
/// was built for: a change applies to a project whatever machine upgrades
/// it. Also return the releases that shipped no records.
fn fetch_records(
    source: &Source,
    releases: &[release::index::Release],
    from: &Version,
    target: &Version,
) -> Result<(Vec<ReleaseRecords>, Vec<String>)> {
    let mut out = Vec::new();
    let mut without: Vec<String> = Vec::new();
    let mut in_range: Vec<&release::index::Release> = releases
        .iter()
        .filter(|r| {
            (!r.version.is_prerelease() || &r.version == target)
                && &r.version > from
                && &r.version <= target
        })
        .collect();
    in_range.sort_by(|a, b| a.version.cmp(&b.version));
    in_range.dedup_by(|a, b| a.version == b.version);
    for r in in_range {
        let document = release::changes(source, r).map_err(|e| miette!("{e}"))?;
        if document.is_none() {
            without.push(r.version.release());
        }
        out.push(ReleaseRecords {
            version: r.version.clone(),
            document,
        });
    }
    Ok((out, without))
}

/// One cluster that failed to build.
struct Failure {
    cluster: String,
    /// What the build printed.
    output: String,
    /// The file that holds `output`.
    log: Option<PathBuf>,
}

/// The clusters that failed to build.
type Failures = Vec<Failure>;

/// What [`Run::build_all`] did.
struct Built {
    clusters: Vec<String>,
    failures: Failures,
}

/// The version the steps reached, or the step that failed and why.
type Outcome = std::result::Result<Version, (Version, Failures)>;

/// One `kix upgrade` run: what it installed, and where it builds.
struct Run {
    dir: PathBuf,
    source: Source,
    work: PathBuf,
    installed_here: Vec<installs::Install>,
    /// The version the upgrade started from.
    from: Version,
    /// The version the project is pinned to now, whose release tag
    /// `flake.nix` may name.
    pinned: Version,
    /// What `kix-upgrade.json` holds, once the steps begin.
    state: Option<UpgradeState>,
    verbose: bool,
}

impl Run {
    fn state(&self) -> &UpgradeState {
        self.state.as_ref().expect("the steps run with a state")
    }

    fn state_mut(&mut self) -> &mut UpgradeState {
        self.state.as_mut().expect("the steps run with a state")
    }

    fn save(&self) -> Result<()> {
        self.state().write(&self.dir).map_err(|e| miette!("{e}"))
    }

    /// Return the `kix` of `version`, installing it first when needed.
    fn kix(&mut self, version: &Version) -> Result<PathBuf> {
        if let Some(i) = installs::installed()
            .into_iter()
            .find(|i| &i.version == version)
        {
            return Ok(i.bin());
        }
        let system = release::system().map_err(|e| miette!("{e}"))?;
        let installed = release::install(
            &Requirement::Exact(version.clone()),
            &system,
            &self.source,
            &|_| {},
        );
        let installed = match installed {
            Ok(i) => i,
            // Once the steps began, the state is saved and a rerun resumes.
            Err(e) if self.state.is_some() => {
                let v = version.release();
                println!("Installing Kix {v}... failed");
                println!();
                println!(
                    "Cannot download Kix {v}: {}.",
                    e.to_string().trim_end_matches('.')
                );
                println!(
                    "Upgrade state is saved in kix-upgrade.json (the {} baseline build is cached).",
                    self.from.release()
                );
                println!(
                    "Next: check your network connection, then run `kix upgrade` to resume at Kix {v}."
                );
                return Err(Stopped(EXIT_REFUSED).into());
            }
            Err(e) => {
                println!("Installing Kix {}... failed", version.release());
                return Err(miette!("{e}"));
            }
        };
        if installed.downloaded {
            println!("Installing Kix {}... ok", version.release());
            self.installed_here.push(installed.install.clone());
        }
        Ok(installed.install.bin())
    }

    /// Save the state as `status`, print `message`, remove what this run
    /// installed, and exit with `code`.
    fn stop(&mut self, status: Status, message: &str, code: Exit) -> Result<()> {
        self.state_mut().status = status;
        self.save()?;
        println!();
        println!("{message}");
        let (from, pinned) = (self.from.clone(), self.pinned.clone());
        self.prune(&from, &pinned);
        exit(code)
    }

    /// Return the text of the stop for an edit a person must make in
    /// `flake.nix`.
    fn edit_message(&self, edit: &kix::pin_library::HandEdit) -> String {
        let state = if self.pinned == self.from {
            format!(
                "flake.nix and flake.lock were not changed. Upgrade state is saved in kix-upgrade.json (the {} baseline build is cached).",
                self.from.release()
            )
        } else {
            format!(
                "flake.nix and flake.lock are pinned to Kix {} (the {} baseline build is cached).",
                self.pinned.release(),
                self.from.release()
            )
        };
        edit_message(edit, &state, "kix upgrade")
    }

    /// Set the result of the step in progress, and save the state.
    fn finish_step(&mut self, result: &str, failures: &Failures) -> Result<()> {
        let step = self
            .state_mut()
            .steps
            .last_mut()
            .expect("a step is in progress");
        step.result = result.to_string();
        step.failed = failures.iter().map(|f| f.cluster.clone()).collect();
        self.save()
    }

    /// Pin the project to `version` and build every cluster. The target is
    /// installed only after Kix knows it can make the flake.nix edit. A
    /// first try of the target (`jump`) names the failed clusters only.
    fn step(&mut self, version: &Version, jump: bool) -> Result<std::result::Result<(), Failures>> {
        self.state_mut().steps.push(Step {
            version: version.release(),
            result: "started".into(),
            failed: Vec::new(),
        });
        self.state_mut().status = Status::FixNeeded;
        self.save()?;
        let plan = match pin::prepare(&self.dir, Some(&self.pinned), version) {
            Ok(plan) => plan,
            Err(pin::PinError::Edit(edit)) => {
                let message = self.edit_message(&edit);
                return self
                    .stop(Status::EditNeeded, &message, EXIT_NEEDS_PERSON)
                    .map(|()| Ok(()));
            }
            Err(pin::PinError::ByHand(message)) => {
                return self
                    .stop(Status::EditNeeded, &message, EXIT_NEEDS_PERSON)
                    .map(|()| Ok(()));
            }
            Err(pin::PinError::Lock(message)) => {
                self.finish_step("failed", &Vec::new())?;
                return self
                    .stop(Status::FixNeeded, &message, EXIT_BUILD_FAILED)
                    .map(|()| Ok(()));
            }
            Err(e) => return Err(miette!("{e}")),
        };
        let kix = self.kix(version)?;
        match pin::pin(Some(&self.pinned), version, &plan) {
            Ok(files) => {
                if !files.is_empty() {
                    println!(
                        "Pinned project to Kix {} (updated {})",
                        version.release(),
                        out::list(&files)
                    );
                }
                self.pinned = version.clone();
            }
            Err(pin::PinError::Lock(message)) => {
                self.finish_step("failed", &Vec::new())?;
                return self
                    .stop(Status::FixNeeded, &message, EXIT_BUILD_FAILED)
                    .map(|()| Ok(()));
            }
            Err(pin::PinError::ByHand(message)) => {
                return self
                    .stop(Status::EditNeeded, &message, EXIT_NEEDS_PERSON)
                    .map(|()| Ok(()));
            }
            Err(pin::PinError::Edit(edit)) => {
                let message = self.edit_message(&edit);
                return self
                    .stop(Status::EditNeeded, &message, EXIT_NEEDS_PERSON)
                    .map(|()| Ok(()));
            }
            Err(e) => return Err(miette!("{e}")),
        }
        let out_dir = self.work.join(version.release());
        let built = self.build_all(&kix, version, &out_dir);
        let failed: Vec<String> = built.failures.iter().map(|f| f.cluster.clone()).collect();
        let how = if failed.is_empty() {
            None
        } else if jump {
            Some(Failed::Names(&failed))
        } else {
            Some(Failed::Count(&failed, built.clusters.len()))
        };
        println!(
            "{}",
            out::build_line(built.clusters.len(), version, false, None, how)
        );
        if built.failures.is_empty() {
            self.finish_step("ok", &Vec::new())?;
            Ok(Ok(()))
        } else {
            self.finish_step("failed", &built.failures)?;
            Ok(Err(built.failures))
        }
    }

    /// Move straight to `goal`. When the project does not build with it,
    /// take `steps` one at a time.
    fn jump(&mut self, goal: &Version, steps: &[Version]) -> Result<Outcome> {
        let single = steps.len() <= 1;
        match self.step(goal, !single)? {
            Ok(()) => Ok(Ok(goal.clone())),
            Err(failures) if single => Ok(Err((goal.clone(), failures))),
            Err(_) => {
                let plan: Vec<String> = steps.iter().map(Version::release).collect();
                println!(
                    "Stepping one minor release at a time ({}):",
                    plan.join(" -> ")
                );
                self.step_through(steps)
            }
        }
    }

    /// Take each of `steps` in turn, and stop at the first that fails.
    fn step_through(&mut self, steps: &[Version]) -> Result<Outcome> {
        let mut last = None;
        for v in steps {
            if let Err(failures) = self.step(v, false)? {
                return Ok(Err((v.clone(), failures)));
            }
            last = Some(v.clone());
        }
        Ok(Ok(last.expect("a stepping upgrade has at least one step")))
    }

    /// Build every cluster of the project with `kix`, Kix `version`, into
    /// `out/<cluster>`, keeping each failed cluster's output in a log file.
    fn build_all(&self, kix: &Path, version: &Version, out: &Path) -> Built {
        let failure = |cluster: &str, output: String| Failure {
            cluster: cluster.to_string(),
            output,
            log: None,
        };
        if out.exists()
            && let Err(e) = installs::remove_tree(out)
        {
            return Built {
                clusters: Vec::new(),
                failures: vec![failure(
                    "(cluster list)",
                    format!("could not clear {}: {e}", out.display()),
                )],
            };
        }
        if let Some(parent) = out.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let names = match clusters(kix, &self.dir) {
            Ok(names) => names,
            Err(e) => {
                return Built {
                    clusters: Vec::new(),
                    failures: vec![failure("(cluster list)", e)],
                };
            }
        };
        let logs = self.work.join("logs").join(version.release());
        let mut failures = Vec::new();
        for cluster in &names {
            let dest = out.join(cluster);
            let dest_text = dest.display().to_string();
            let keep_metadata: &[&str] = if new_command_line(version) {
                &["--with-kix-metadata"]
            } else {
                &["--for", "audit"]
            };
            let args = [
                &["export", cluster.as_str(), "--out", &dest_text][..],
                keep_metadata,
            ]
            .concat();
            if let Err(output) = run_kix(kix, &self.dir, &args) {
                let path = logs.join(format!("{cluster}.log"));
                let log = std::fs::create_dir_all(&logs)
                    .and_then(|()| std::fs::write(&path, &output))
                    .ok()
                    .map(|()| path);
                failures.push(Failure {
                    cluster: cluster.clone(),
                    output,
                    log,
                });
            }
        }
        if failures.is_empty() {
            let _ = std::fs::create_dir_all(out);
        }
        Built {
            clusters: names,
            failures,
        }
    }

    /// Remove each version this run installed, except `from` and `kept`.
    fn prune(&self, from: &Version, kept: &Version) {
        let mut first = true;
        for i in &self.installed_here {
            if &i.version == from || &i.version == kept {
                continue;
            }
            match installs::remove_tree(&i.dir) {
                Ok(()) if self.verbose => {
                    if first {
                        println!();
                        first = false;
                    }
                    println!("Removed temporary Kix {}.", i.version.release())
                }
                Ok(()) => {}
                Err(e) => {
                    tracing::warn!(path = %i.dir.display(), error = %e, "could not remove a version of Kix")
                }
            }
        }
    }
}

/// Run `kix` for the project in `dir` with `args`, as the Kix chosen for the
/// project. Return its stdout, or its stderr when it fails.
fn run_kix(kix: &Path, dir: &Path, args: &[&str]) -> std::result::Result<String, String> {
    let chooser = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("kix"));
    let out = Command::new(kix)
        .arg("--flake")
        .arg(dir)
        .args(args)
        .env(crate::select::SELECTED_BY_VAR, chooser)
        .env_remove("KIX_FLAKE")
        .output()
        .map_err(|e| format!("could not run {}: {e}", kix.display()))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        Err(if err.is_empty() {
            format!("{} exited with {}", kix.display(), out.status)
        } else {
            err
        })
    }
}

/// Return the clusters of the project, as `kix` lists them.
fn clusters(kix: &Path, dir: &Path) -> std::result::Result<Vec<String>, String> {
    let out = run_kix(kix, dir, &["-o", "json", "list", "clusters"])?;
    if out.trim().is_empty() {
        return Ok(Vec::new());
    }
    serde_json::from_str(&out)
        .map_err(|e| format!("`kix list clusters` printed no list of clusters: {e}"))
}

/// Return whether Kix `version` takes the command line of Kix 0.10, which
/// renamed the flags this module passes to `kix export` and `kix list
/// packages`. Earlier versions refuse the new names, and later ones refuse
/// the old.
fn new_command_line(version: &Version) -> bool {
    let first = Version {
        pre: Some("rc.4".to_string()),
        ..Version::new(0, 10, 0)
    };
    *version >= first
}

/// Return the packages the project's clusters install, or `None` when Kix
/// `version` at `kix` cannot list them. `kix list packages` names instances,
/// so instance names stand in for package names.
fn packages_in_use(kix: &Path, version: &Version, dir: &Path) -> Option<BTreeSet<String>> {
    let mut in_use = BTreeSet::new();
    for cluster in clusters(kix, dir).ok()? {
        let mut args = vec!["-o", "json", "list", "packages"];
        if !new_command_line(version) {
            args.push("--cluster");
        }
        args.push(&cluster);
        let out = run_kix(kix, dir, &args).ok()?;
        if out.trim().is_empty() {
            continue;
        }
        let rows: Vec<serde_json::Value> = serde_json::from_str(&out).ok()?;
        for row in rows {
            // A row this Kix cannot read leaves the list unknown.
            let (Some(name), Some(status)) = (row["name"].as_str(), row["status"].as_str()) else {
                return None;
            };
            if status != "available" {
                in_use.insert(name.to_string());
            }
        }
    }
    Some(in_use)
}

/// Print each failed cluster's error, and where its full output is.
fn print_failures(failures: &Failures) {
    for f in failures {
        println!();
        println!("  Cluster {}:", f.cluster);
        for line in out::excerpt(&f.output) {
            println!("    {line}");
        }
        if let Some(log) = &f.log {
            println!("    Full build log: {}", log.display());
        }
    }
}

/// Print every "Config changes required" note of the releases the failed
/// step moved through, with likely matches marked.
fn print_matching(matching: &[Applying], previous: &Version, failing: &Version) {
    if matching.is_empty() {
        return;
    }
    let releases: BTreeSet<&Version> = matching.iter().map(|a| &a.release).collect();
    let several = releases.len() > 1;
    println!();
    match (matching.len(), several) {
        (1, _) => println!(
            "  Config change required in Kix {}:",
            matching[0].release.release()
        ),
        (_, false) => println!(
            "  Config changes required in Kix {}:",
            matching[0].release.release()
        ),
        _ => println!(
            "  Config changes required (Kix {} -> {}):",
            previous.release(),
            failing.release()
        ),
    }
    if matching.iter().any(|a| a.likely) {
        println!("    * may affect this project (package name matches an instance in use)");
    }
    for a in matching {
        let gutter = if a.likely { "  * " } else { "    " };
        let mut head = format!("{gutter}[{}]", a.reference());
        if !a.record.packages.is_empty() {
            head.push_str(&format!(" {}", out::list(&a.record.packages)));
        }
        if several || a.record.packages.is_empty() {
            head.push_str(&format!(" ({})", a.release.release()));
        }
        head.push(':');
        for line in out::wrap(&head, 6, &a.record.body) {
            println!("{line}");
        }
    }
}

/// What the comparison of the builds found.
struct Report {
    any_changed: bool,
    sensitive: usize,
    review: out::Review,
}

/// Compare the builds in `before` and `after`, print what changed, grouped
/// by clusters that changed the same way, and return what the review list
/// needs.
fn report_changes(before: &Path, after: &Path, from: &Version, to: &Version) -> Result<Report> {
    let names = |d: &Path| -> BTreeSet<String> {
        std::fs::read_dir(d)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().is_dir())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect()
    };
    let clusters: BTreeSet<String> = names(before).union(&names(after)).cloned().collect();
    let load = |d: PathBuf| -> Result<BTreeMap<String, compare::Object>> {
        if d.is_dir() {
            compare::load_dir(&d).map_err(|e| miette!("{e}"))
        } else {
            Ok(BTreeMap::new())
        }
    };
    let mut groups: BTreeMap<Vec<String>, Vec<String>> = BTreeMap::new();
    let mut report = Report {
        any_changed: false,
        sensitive: 0,
        review: out::Review::default(),
    };
    for cluster in &clusters {
        let changes = compare::compare(&load(before.join(cluster))?, &load(after.join(cluster))?);
        report.any_changed |= !changes.is_empty();
        report.sensitive += changes.iter().filter(|c| c.sensitive).count();
        report.review.add(cluster, &changes);
        groups
            .entry(out::change_lines(&changes))
            .or_default()
            .push(cluster.clone());
    }
    println!();
    println!("Manifest changes ({} -> {}):", from.release(), to.release());
    let (same, changed): (Vec<_>, Vec<_>) = groups.iter().partition(|(lines, _)| lines.is_empty());
    for (_, clusters) in same {
        println!("  {}: no objects changed", out::list(clusters));
    }
    for (lines, clusters) in changed {
        println!("  {}:", out::list(clusters));
        for line in lines {
            println!("    {line}");
        }
    }
    Ok(report)
}

/// Return the references of the applying records by kind name.
fn by_kind(applying: &[Applying]) -> BTreeMap<String, Vec<String>> {
    let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for a in applying {
        out.entry(a.record.kind.name().to_string())
            .or_default()
            .push(a.reference());
    }
    out
}

/// Return the applying records that change stored data with no error.
fn data_changes(applying: &[Applying]) -> Vec<DataChange> {
    applying
        .iter()
        .filter(|a| a.record.kind == Kind::Silent && a.record.touches_data)
        .map(|a| DataChange {
            reference: a.reference(),
            release: a.release.release(),
            body: a.record.body.trim().to_string(),
        })
        .collect()
}

/// What a preview knows about the project.
#[derive(Clone, Copy)]
enum Known {
    /// The packages in use and how many clusters there are.
    Clusters(usize),
    /// The packages in use only.
    Packages,
    /// Neither: every change in the range counts.
    Nothing,
}

impl Known {
    fn of(packages: bool, clusters: Option<usize>) -> Self {
        match (packages, clusters) {
            (true, Some(n)) => Known::Clusters(n),
            (true, None) => Known::Packages,
            (false, _) => Known::Nothing,
        }
    }
}

struct Preview<'a> {
    from: &'a Version,
    target: &'a Version,
    steps: &'a [Version],
    stop: Option<&'a (Version, Version)>,
    applying: &'a [Applying],
    known: Known,
    without_notes: &'a [String],
    verbose: bool,
    /// The command that runs this upgrade, as the person typed it without
    /// `--dry-run`.
    command: &'a str,
}

fn preview(p: &Preview) {
    let (from, target) = (p.from.release(), p.target.release());
    println!("Kix {from} -> {target} (dry run, no files changed)");
    if let Some((stop, until)) = p.stop {
        println!();
        println!(
            "Kix {} must be deployed to every cluster before upgrading further, so this upgrade will stop at Kix {} on the way to {target}.",
            stop.release(),
            until.release()
        );
    }
    if !p.without_notes.is_empty() {
        println!();
        for line in out::without_notes_paragraph(p.without_notes) {
            println!("{line}");
        }
    }
    let listed = out::listed(p.applying).len();
    let notes = out::notes(p.applying, true, p.from, p.target);
    if listed > 0 {
        let changes = if listed == 1 {
            "1 change".to_string()
        } else {
            format!("{listed} changes")
        };
        println!();
        println!("{changes} between {from} and {target}:");
        let legend = match p.known {
            Known::Clusters(n) => out::legend(p.applying, Some(n)),
            Known::Packages => out::legend(p.applying, None),
            Known::Nothing => Some(format!(
                "  (current Kix {from} is not installed, so likely matches are not marked)"
            )),
        };
        if let Some(legend) = legend {
            println!("{legend}");
        }
        println!();
    } else if p.without_notes.is_empty() {
        println!();
        println!("No breaking, security, or upgrade notes between {from} and {target}.");
    }
    if !notes.is_empty() {
        if listed == 0 {
            println!();
        }
        for line in notes {
            println!("{line}");
        }
    }
    if p.verbose {
        let to_install = p
            .steps
            .iter()
            .filter(|v| !installs::installed().iter().any(|i| &i.version == *v))
            .count();
        let versions: Vec<String> = p.steps.iter().map(Version::release).collect();
        let versions = out::list(&versions);
        println!();
        match to_install {
            0 => println!("Stepping plan if direct jump fails: {versions} (all installed)."),
            1 => println!(
                "Stepping plan if direct jump fails: {versions} (1 version would be installed)."
            ),
            n => println!(
                "Stepping plan if direct jump fails: {versions} ({n} versions would be installed)."
            ),
        }
    }
    let config: Vec<String> = p
        .applying
        .iter()
        .filter(|a| a.record.kind == Kind::Error)
        .map(Applying::reference)
        .collect();
    println!();
    match config.as_slice() {
        [] => {}
        [one] => println!(
            "`kix upgrade` will stop at the step for [{one}] until you make the config change above."
        ),
        many => println!(
            "`kix upgrade` will stop for [{}] until you make the config changes above.",
            many.join("], [")
        ),
    }
    println!("Next: run `{}`.", p.command);
}

/// Add `refs` to the acknowledged data changes in `kix-upgrade.json`.
fn acknowledge(dir: &Path, refs: &[String]) -> Result<()> {
    let Some(mut state) = UpgradeState::read(dir).map_err(|e| miette!("{e}"))? else {
        return refuse(&format!(
            "No kix-upgrade.json found in {}; nothing to acknowledge.",
            dir.display()
        ));
    };
    let mut wanted = Vec::new();
    for r in refs {
        let id = kix::changes::normalize_id(r).unwrap_or_else(|| r.clone());
        if !state.data_changes.iter().any(|d| d.reference == id) {
            let pending: Vec<&str> = state
                .unacknowledged()
                .iter()
                .map(|d| d.reference.as_str())
                .collect();
            return refuse(&if pending.is_empty() {
                format!(
                    "`{r}` is not a pending data migration in kix-upgrade.json (no pending data migrations)."
                )
            } else {
                format!(
                    "`{r}` is not a pending data migration in kix-upgrade.json (pending: {}).",
                    out::list(&pending)
                )
            });
        }
        wanted.push(id);
    }
    for id in &wanted {
        if !state.acknowledged.contains(id) {
            state.acknowledged.push(id.clone());
        }
    }
    state.write(dir).map_err(|e| miette!("{e}"))?;
    let acked = out::list(&wanted);
    let remaining: Vec<&str> = state
        .unacknowledged()
        .iter()
        .map(|d| d.reference.as_str())
        .collect();
    match remaining.len() {
        0 => println!("Acknowledged {acked} in kix-upgrade.json. You can now run `kix deploy`."),
        1 => println!(
            "Acknowledged {acked} in kix-upgrade.json. 1 data migration still requires `--acknowledge` before `kix deploy`: {}.",
            remaining[0]
        ),
        n => println!(
            "Acknowledged {acked} in kix-upgrade.json. {n} data migrations still require `--acknowledge` before `kix deploy`: {}.",
            out::list(&remaining)
        ),
    }
    Ok(())
}

/// Refuse a deploy while `kix-upgrade.json` in `dir` lists a change to
/// stored data that no one has acknowledged.
pub fn check_deploy(dir: &Path) -> Result<()> {
    let Some(state) = UpgradeState::read(dir).map_err(|e| miette!("{e}"))? else {
        return Ok(());
    };
    let open = state.unacknowledged();
    if open.is_empty() {
        return Ok(());
    }
    let one = open.len() == 1;
    let mut text = format!(
        "Deploy blocked: upgrade to Kix {} includes {}.\nNo clusters were contacted.\n",
        state.to,
        if one {
            "an unacknowledged data migration"
        } else {
            "unacknowledged data migrations"
        }
    );
    for d in &open {
        text.push('\n');
        text.push_str(&format!(
            "  [{}] ({}, moves stored data):\n",
            d.reference, d.release
        ));
        for line in out::wrap("    ", 4, &d.body) {
            text.push_str(&format!("{line}\n"));
        }
    }
    let refs: Vec<&str> = open.iter().map(|d| d.reference.as_str()).collect();
    text.push_str(&format!(
        "\nNext: once you are ready for {}, run:\n  kix upgrade --acknowledge {}\nThen run `kix deploy` again.",
        if one {
            "this migration"
        } else {
            "these migrations"
        },
        refs.join(" ")
    ));
    eprintln!("{text}");
    exit(EXIT_REFUSED)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_version_the_project_is_on_comes_from_flake_lock() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(project_version(dir.path()).unwrap(), None);
        std::fs::write(
            dir.path().join("flake.lock"),
            r#"{"root": "root", "version": 7, "nodes": {
                "root": {"inputs": {"kix": "kix"}},
                "kix": {"original": {"type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.8.0-rc.1"}}
            }}"#,
        )
        .unwrap();
        let v = project_version(dir.path()).unwrap().unwrap();
        assert_eq!(v.release(), "0.8.0-rc.1");
        assert!(v < "0.8.0".parse().unwrap());
    }
}
