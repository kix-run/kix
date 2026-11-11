//! `kix upgrade`: move a project to a newer version of Kix.
//!
//! The Kix that runs this command never evaluates the project. Every list
//! and build runs as a subprocess of the installed Kix that matches the
//! project at that step, handed over as `select` does. From another version
//! it reads only the cluster list, the package list, and an exported
//! manifest directory.

mod compare;
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
use plan::{Applying, ReleaseRecords};
use state::{DataChange, Status, Step, UpgradeState};

/// A build failed.
const EXIT_BUILD_FAILED: i32 = 2;
/// The upgrade finished, and a person should read what changed.
const EXIT_NEEDS_PERSON: i32 = 3;

pub fn run(args: &UpgradeArgs, global: &GlobalArgs) -> Result<()> {
    let dir = super::project_dir(&global.flake)
        .filter(|d| d.is_dir())
        .ok_or_else(|| {
            miette!(
                "`kix upgrade` changes the project's files, so --flake must name a local directory, not {}",
                global.flake
            )
        })?;
    if !args.ack.is_empty() {
        return acknowledge(&dir, &args.ack);
    }
    let config = kix::project::ProjectConfig::read(Some(&dir), None).map_err(|e| miette!("{e}"))?;
    let previous = UpgradeState::read(&dir).map_err(|e| miette!("{e}"))?;
    let source = Source::from_env();
    let system = release::system().map_err(|e| miette!("{e}"))?;
    let index = release::fetch_index(&source).map_err(|e| miette!("{e}"))?;
    let releases = plan::usable(&index.releases, &system);

    // A run that a build failure, a flake.nix edit, or an interruption
    // stopped goes on from where it was.
    let resume = previous
        .clone()
        .filter(|s| matches!(s.status, Status::FixNeeded | Status::EditNeeded));
    if resume.is_none()
        && !args.preview
        && let Some(p) = &previous
        && !p.unacknowledged().is_empty()
    {
        let refs: Vec<&str> = p
            .unacknowledged()
            .iter()
            .map(|d| d.reference.as_str())
            .collect();
        return Err(miette!(
            "The last upgrade, to Kix {}, changes stored data, and no one has acknowledged it: {}. Read the changes in {}, run `kix upgrade --ack {}`, then run `kix upgrade` again.",
            p.to,
            refs.join(", "),
            state::FILE,
            refs.join(" ")
        ));
    }

    let from: Version = match &resume {
        Some(s) => s
            .from
            .parse()
            .map_err(|_| miette!("{} names no version in `from`", state::FILE))?,
        None => current_version(&dir, &config)?,
    };
    let to = match args.to.as_deref() {
        None | Some("latest") => None,
        Some(text) => Some(
            text.parse::<Requirement>()
                .map_err(|e| miette!("--to: {e}"))?,
        ),
    };
    let min_age =
        match &args.min_age {
            Some(text) => Some(kix::project::parse_min_age(text).ok_or_else(|| {
                miette!("--min-age {text} is not a number of days. Write it as 7d")
            })?),
            None => config.upgrade_min_age,
        };
    let today = chrono::Utc::now().date_naive();
    let target = plan::choose_target(&releases, to.as_ref(), min_age, today).ok_or_else(|| {
        miette!(
            "no Kix release matches{}{} for {system}",
            to.as_ref().map(|r| format!(" {r}")).unwrap_or_default(),
            min_age
                .map(|d| format!(" that is at least {d} days old"))
                .unwrap_or_default()
        )
    })?;
    if target <= from {
        if resume.is_some() {
            return Err(miette!(
                "{} holds an unfinished upgrade from Kix {}, and Kix {} is not newer. Choose a newer version with --to, or delete {} to start again.",
                state::FILE,
                from.release(),
                target.release(),
                state::FILE
            ));
        }
        println!(
            "This project uses Kix {}, and Kix {} is the newest release that matches. There is nothing to upgrade.",
            from.release(),
            target.release()
        );
        return Ok(());
    }

    let records = fetch_records(&source, &index.releases, &from, &target)?;
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
        pinned: match &config.kix {
            Some(Requirement::Exact(v)) => v.clone(),
            _ => from.clone(),
        },
        state: None,
    };
    let saved_in_use = |s: &UpgradeState| {
        s.packages_in_use
            .as_ref()
            .map(|p| p.iter().cloned().collect::<BTreeSet<String>>())
    };

    if args.preview {
        let from_kix = installs::installed()
            .into_iter()
            .find(|i| i.version == from)
            .map(|i| i.bin());
        let (in_use, knew) = match (&resume, &from_kix) {
            (Some(s), _) => (saved_in_use(s), s.packages_in_use.is_some()),
            (None, Some(kix)) => (packages_in_use(kix, &dir), true),
            (None, None) => (None, false),
        };
        let applying = plan::applying(&records, &from, &goal, in_use.as_ref());
        preview(&from, &target, &steps, stop.as_ref(), &applying, knew);
        return Ok(());
    }

    let before = run.work.join("before");
    let in_use = match &resume {
        // After the first pin, the version the upgrade started from can no
        // longer evaluate the project, so it is never asked again.
        Some(s) => {
            if s.before != before || !before.is_dir() {
                return Err(miette!(
                    "{} holds an unfinished upgrade from Kix {}, but the builds made with Kix {} at its start are gone ({}). Delete {} and run `kix upgrade` again. The comparison then starts from the version the project is pinned to now.",
                    state::FILE,
                    from.release(),
                    from.release(),
                    before.display(),
                    state::FILE
                ));
            }
            saved_in_use(s)
        }
        None => {
            let from_kix = run.kix(&from)?;
            let names = clusters(&from_kix, &dir).map_err(|e| miette!("{e}"))?;
            if names.is_empty() {
                return Err(miette!(
                    "Kix {} lists no clusters in this project, so Kix has nothing to build or compare.",
                    from.release()
                ));
            }
            let in_use = packages_in_use(&from_kix, &dir);
            println!(
                "Building every cluster with Kix {}, the version this project uses now.",
                from.release()
            );
            if let Err(failures) = build_all(&from_kix, &dir, &before) {
                print_failures(&failures);
                println!(
                    "The project does not build with Kix {}. Fix the build first, then run `kix upgrade` again.",
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
        unexplained_changes: 0,
        sensitive_changes: 0,
        cli_hits: Vec::new(),
        before: before.clone(),
        packages_in_use: in_use.as_ref().map(|p| p.iter().cloned().collect()),
    });
    run.save()?;

    let last = run.state().steps.last().cloned();
    let result = match last {
        None => {
            println!("Upgrading to Kix {}.", goal.release());
            run.jump(&goal, &steps)?
        }
        Some(last) => {
            let at: Version = last
                .version
                .parse()
                .map_err(|_| miette!("{} names no version in its last step", state::FILE))?;
            println!(
                "Resuming the upgrade to Kix {} at Kix {}.",
                goal.release(),
                at.release()
            );
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
        let explaining = plan::applying(&records, previous_step, &failing, in_use.as_ref());
        print_records(
            &format!("Change records of Kix {}", failing.release()),
            &explaining,
        );
        println!(
            "The project does not build with Kix {}, and is pinned to it. Fix the errors above, then run `kix upgrade` again to continue to Kix {}.",
            failing.release(),
            goal.release()
        );
        run.state_mut().status = Status::FixNeeded;
        run.save()?;
        run.prune(&from, &failing);
        return exit(EXIT_BUILD_FAILED);
    }
    let mut state = run.state.take().expect("set above");

    let after = run.work.join(goal.release());
    let explaining: BTreeSet<String> = applying
        .iter()
        .flat_map(|a| a.record.packages.iter().cloned())
        .collect();
    let (unexplained, sensitive) = report_changes(&before, &after, &explaining)?;
    state.unexplained_changes = unexplained;
    state.sensitive_changes = sensitive;

    print_records("Change records that apply to this project", &applying);

    let needles: Vec<String> = applying
        .iter()
        .flat_map(|a| a.record.cli.iter().cloned())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if !needles.is_empty() {
        match search::tracked(&dir) {
            Some(files) => state.cli_hits = search::search(&dir, &files, &needles),
            None => println!(
                "The project is not in a git repository, so Kix did not search it for changed commands."
            ),
        }
        if !state.cli_hits.is_empty() {
            println!("\nLines that use a command or flag that changed:");
            for hit in &state.cli_hits {
                println!("  {}:{}: {}", hit.file, hit.line, hit.text);
            }
        }
    }

    run.prune(&from, &goal);

    let silent = plan::of_kind(&applying, Kind::Silent);
    let mut reasons = Vec::new();
    if let Some((r, _)) = &stop {
        reasons.push(format!(
            "Deploy every cluster with Kix {}, then run `kix upgrade` again. Kix {} has a change that every cluster must deploy before it upgrades further.",
            goal.release(),
            r.release()
        ));
    }
    if unexplained > 0 {
        reasons.push(format!(
            "{} no change record that explains {}. Read {} before you deploy.",
            objects(unexplained, "has", "have"),
            them(unexplained),
            them(unexplained)
        ));
    }
    if sensitive > 0 {
        reasons.push(format!(
            "{} access, network reach, or certificates. Read {} before you deploy.",
            objects(sensitive, "controls", "control"),
            them(sensitive)
        ));
    }
    if !silent.is_empty() {
        reasons.push(format!(
            "Some things work differently with no error: {}. Read these records before you deploy.",
            silent
                .iter()
                .map(|a| a.reference())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    state
        .acknowledged
        .retain(|a| state.data_changes.iter().any(|d| &d.reference == a));
    let unack: Vec<String> = state
        .unacknowledged()
        .iter()
        .map(|d| d.reference.clone())
        .collect();
    if !unack.is_empty() {
        reasons.push(format!(
            "`kix deploy` waits until you acknowledge each change to stored data: kix upgrade --ack {}",
            unack.join(" ")
        ));
    }
    state.status = if stop.is_some() {
        Status::RequiredStop
    } else if reasons.is_empty() {
        Status::Done
    } else {
        Status::NeedsPerson
    };
    state.write(&dir).map_err(|e| miette!("{e}"))?;

    println!(
        "\nThe project builds with Kix {} and is pinned to it.",
        goal.release()
    );
    if reasons.is_empty() {
        return Ok(());
    }
    for r in &reasons {
        println!("{r}");
    }
    exit(EXIT_NEEDS_PERSON)
}

/// Return "1 changed object has" or "2 changed objects have".
fn objects(n: usize, one: &str, many: &str) -> String {
    if n == 1 {
        format!("1 changed object {one}")
    } else {
        format!("{n} changed objects {many}")
    }
}

fn them(n: usize) -> &'static str {
    if n == 1 { "it" } else { "them" }
}

/// Flush stdout and exit with `code`.
fn exit(code: i32) -> Result<()> {
    let _ = std::io::Write::flush(&mut std::io::stdout());
    std::process::exit(code)
}

/// Return the version of Kix the project uses: the exact version in
/// `kix.toml`, or else the version of its Kix library.
fn current_version(dir: &Path, config: &kix::project::ProjectConfig) -> Result<Version> {
    if let Some(Requirement::Exact(v)) = &config.kix {
        return Ok(v.clone());
    }
    super::select_builder_for(dir).map_err(|e| miette!("{e}"))?;
    kix::runtime::runtime().map_err(|e| miette!("{e}"))?;
    match kix::library::eval_version(dir, &[]) {
        kix::library::LibraryVersion::Known(v) => v.parse().map_err(|_| {
            miette!("the project's Kix library names version {v}, which is not a Kix version")
        }),
        _ => Err(miette!(
            "Kix cannot tell which version of Kix this project uses. Set the exact version in kix.toml, such as kix = \"{}\", then run `kix upgrade` again",
            kix::version::running().release()
        )),
    }
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
/// that is not a prerelease, whichever systems it was built for: a change
/// applies to a project whatever machine upgrades it.
fn fetch_records(
    source: &Source,
    releases: &[release::index::Release],
    from: &Version,
    target: &Version,
) -> Result<Vec<ReleaseRecords>> {
    let mut out = Vec::new();
    let mut without: Vec<String> = Vec::new();
    let mut in_range: Vec<&release::index::Release> = releases
        .iter()
        .filter(|r| !r.version.is_prerelease() && &r.version > from && &r.version <= target)
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
    if !without.is_empty() {
        without.sort_by_key(|v| v.parse::<Version>().ok());
        println!(
            "These releases have no change records: {}. Read their sections of CHANGELOG.md.",
            without.join(", ")
        );
    }
    Ok(out)
}

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
}

/// The clusters that failed to build, each with its error.
type Failures = Vec<(String, String)>;

/// The version the steps reached, or the step that failed and why.
type Outcome = std::result::Result<Version, (Version, Failures)>;

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
            &|v| println!("Installing Kix {}.", v.release()),
        )
        .map_err(|e| miette!("{e}"))?;
        if installed.downloaded {
            self.installed_here.push(installed.install.clone());
        }
        Ok(installed.install.bin())
    }

    /// Save the state as `status`, print `message`, remove what this run
    /// installed, and exit with `code`.
    fn stop(&mut self, status: Status, message: &str, code: i32) -> Result<()> {
        self.state_mut().status = status;
        self.save()?;
        println!("{message}");
        let (from, pinned) = (self.from.clone(), self.pinned.clone());
        self.prune(&from, &pinned);
        exit(code)
    }

    /// Set the result of the step in progress, and save the state.
    fn finish_step(&mut self, result: &str, failures: &Failures) -> Result<()> {
        let step = self
            .state_mut()
            .steps
            .last_mut()
            .expect("a step is in progress");
        step.result = result.to_string();
        step.failed = failures.iter().map(|(c, _)| c.clone()).collect();
        self.save()
    }

    /// Pin the project to `version` and build every cluster. The target is
    /// installed only after Kix knows it can make the flake.nix edit.
    fn step(&mut self, version: &Version) -> Result<std::result::Result<(), Failures>> {
        self.state_mut().steps.push(Step {
            version: version.release(),
            result: "started".into(),
            failed: Vec::new(),
        });
        self.state_mut().status = Status::FixNeeded;
        self.save()?;
        if let Some(message) = pin::needs_hand_edit(&self.dir, &self.pinned, version) {
            return self
                .stop(Status::EditNeeded, &message, EXIT_NEEDS_PERSON)
                .map(|()| Ok(()));
        }
        let kix = self.kix(version)?;
        match pin::pin(&self.dir, &self.pinned, version) {
            Ok(notes) => {
                for note in notes {
                    println!("  {note}");
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
            Err(e) => return Err(miette!("{e}")),
        }
        println!("Building every cluster with Kix {}.", version.release());
        let built = build_all(&kix, &self.dir, &self.work.join(version.release()));
        match &built {
            Ok(()) => self.finish_step("ok", &Vec::new())?,
            Err(failures) => self.finish_step("failed", failures)?,
        }
        Ok(built)
    }

    /// Move straight to `goal`. When the project does not build with it,
    /// take `steps` one at a time.
    fn jump(&mut self, goal: &Version, steps: &[Version]) -> Result<Outcome> {
        match self.step(goal)? {
            Ok(()) => Ok(Ok(goal.clone())),
            Err(failures) if steps.len() <= 1 => Ok(Err((goal.clone(), failures))),
            Err(_) => {
                println!(
                    "The project does not build with Kix {}. Trying one minor release at a time.",
                    goal.release()
                );
                self.step_through(steps)
            }
        }
    }

    /// Take each of `steps` in turn, and stop at the first that fails.
    fn step_through(&mut self, steps: &[Version]) -> Result<Outcome> {
        let mut last = None;
        for v in steps {
            if let Err(failures) = self.step(v)? {
                return Ok(Err((v.clone(), failures)));
            }
            last = Some(v.clone());
        }
        Ok(Ok(last.expect("a stepping upgrade has at least one step")))
    }

    /// Remove each version this run installed, except `from` and `kept`.
    fn prune(&self, from: &Version, kept: &Version) {
        for i in &self.installed_here {
            if &i.version == from || &i.version == kept {
                continue;
            }
            match installs::remove_tree(&i.dir) {
                Ok(()) => println!(
                    "Removed Kix {}, which this upgrade installed only to build with.",
                    i.version.release()
                ),
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

/// Return the packages the project's clusters install, or `None` when `kix`
/// cannot list them. `kix list packages --cluster` names instances, so
/// instance names stand in for package names.
fn packages_in_use(kix: &Path, dir: &Path) -> Option<BTreeSet<String>> {
    let mut in_use = BTreeSet::new();
    for cluster in clusters(kix, dir).ok()? {
        let out = run_kix(
            kix,
            dir,
            &["-o", "json", "list", "packages", "--cluster", &cluster],
        )
        .ok()?;
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

/// Build every cluster of the project with `kix` into `out/<cluster>`.
fn build_all(kix: &Path, dir: &Path, out: &Path) -> std::result::Result<(), Failures> {
    if out.exists() {
        installs::remove_tree(out).map_err(|e| {
            vec![(
                String::new(),
                format!("could not clear {}: {e}", out.display()),
            )]
        })?;
    }
    if let Some(parent) = out.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let names = clusters(kix, dir).map_err(|e| vec![("(cluster list)".to_string(), e)])?;
    let mut failures = Vec::new();
    for cluster in &names {
        let dest = out.join(cluster);
        let dest_text = dest.display().to_string();
        if let Err(e) = run_kix(
            kix,
            dir,
            &["export", cluster, "--out", &dest_text, "--for", "audit"],
        ) {
            failures.push((cluster.clone(), e));
        }
    }
    if failures.is_empty() {
        let _ = std::fs::create_dir_all(out);
        Ok(())
    } else {
        Err(failures)
    }
}

fn print_failures(failures: &Failures) {
    for (cluster, error) in failures {
        println!("\nCluster {cluster}:");
        for line in error.lines() {
            println!("  {line}");
        }
    }
}

/// Compare the builds in `before` and `after`, print what changed, grouped
/// by clusters that changed the same way, and return the counts of
/// unexplained and sensitive changes.
fn report_changes(
    before: &Path,
    after: &Path,
    explaining: &BTreeSet<String>,
) -> Result<(usize, usize)> {
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
    let (mut unexplained, mut sensitive) = (0, 0);
    for cluster in &clusters {
        let changes = compare::compare(
            &load(before.join(cluster))?,
            &load(after.join(cluster))?,
            explaining,
        );
        unexplained += changes.iter().filter(|c| !c.explained).count();
        sensitive += changes.iter().filter(|c| c.sensitive).count();
        groups
            .entry(compare::summary(&changes))
            .or_default()
            .push(cluster.clone());
    }
    println!();
    for (summary, clusters) in &groups {
        let label = if clusters.len() == 1 {
            "Cluster"
        } else {
            "Clusters"
        };
        if summary.is_empty() {
            println!("{label} {}: no objects changed.", clusters.join(", "));
        } else {
            println!("{label} {}:", clusters.join(", "));
            for line in summary {
                println!("  {line}");
            }
        }
    }
    Ok((unexplained, sensitive))
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

/// Print the records in `applying` under `title`, grouped by what the
/// reader must do. Added, changed, and fixed records print as a count.
fn print_records(title: &str, applying: &[Applying]) {
    if applying.is_empty() {
        return;
    }
    println!("\n{title}:");
    let groups = [
        (Kind::Error, "Edits needed"),
        (Kind::Silent, "Changes with no error"),
        (Kind::Note, "Upgrade notes"),
        (Kind::Security, "Security"),
    ];
    for (kind, heading) in groups {
        let of = plan::of_kind(applying, kind);
        if of.is_empty() {
            continue;
        }
        println!("  {heading}:");
        for a in of {
            println!(
                "    [{}] Kix {}: {}",
                a.reference(),
                a.release.release(),
                one_line(&a.record.body)
            );
            for c in &a.record.cli {
                println!("      changes the command or flag {c}");
            }
            if a.record.required_stop {
                println!(
                    "      every cluster must deploy Kix {} before upgrading further",
                    a.release.release()
                );
            }
        }
    }
    let rest = applying
        .iter()
        .filter(|a| matches!(a.record.kind, Kind::Added | Kind::Changed | Kind::Fixed))
        .count();
    if rest > 0 {
        println!("  {rest} other records add, change, or fix things. Read them in the CHANGELOG.");
    }
}

fn one_line(body: &str) -> String {
    body.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn preview(
    from: &Version,
    target: &Version,
    steps: &[Version],
    stop: Option<&(Version, Version)>,
    applying: &[Applying],
    knew_packages: bool,
) {
    println!(
        "This project uses Kix {}. The newest release that matches is Kix {}.",
        from.release(),
        target.release()
    );
    if let Some((r, until)) = stop {
        println!(
            "Kix {} has a change that every cluster must deploy before it upgrades further, so this upgrade stops at Kix {}.",
            r.release(),
            until.release()
        );
    }
    let to_install = steps
        .iter()
        .filter(|v| !installs::installed().iter().any(|i| &i.version == *v))
        .count();
    let list: Vec<String> = steps.iter().map(Version::release).collect();
    println!(
        "If the project does not build with the newest version at once, Kix takes these steps: {}. {}",
        list.join(", "),
        match to_install {
            0 => "Every one of those versions is installed.".to_string(),
            1 => "That installs 1 version of Kix.".to_string(),
            n => format!("That installs {n} versions of Kix."),
        }
    );
    if !knew_packages {
        println!(
            "Kix {} is not installed, so the list below counts every record, including those for packages this project may not use.",
            from.release()
        );
    }
    if applying.is_empty() {
        println!("No change records apply to this project.");
    } else {
        print_records("Change records that apply to this project", applying);
    }
}

/// Add `refs` to the acknowledged data changes in `kix-upgrade.json`.
fn acknowledge(dir: &Path, refs: &[String]) -> Result<()> {
    let mut state = UpgradeState::read(dir)
        .map_err(|e| miette!("{e}"))?
        .ok_or_else(|| {
            miette!(
                "{} has no {}, so there is nothing to acknowledge. Run `kix upgrade` first",
                dir.display(),
                state::FILE
            )
        })?;
    for r in refs {
        let wanted = kix::changes::normalize_id(r).unwrap_or_else(|| r.clone());
        if !state.data_changes.iter().any(|d| d.reference == wanted) {
            let known: Vec<&str> = state
                .data_changes
                .iter()
                .map(|d| d.reference.as_str())
                .collect();
            return Err(miette!(
                "{r} is not a change to stored data in {}. {}",
                state::FILE,
                if known.is_empty() {
                    "It lists none.".to_string()
                } else {
                    format!("It lists: {}.", known.join(", "))
                }
            ));
        }
        if !state.acknowledged.contains(&wanted) {
            state.acknowledged.push(wanted.clone());
        }
        println!("Acknowledged {wanted}.");
    }
    state.write(dir).map_err(|e| miette!("{e}"))
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
    let mut text = format!(
        "The upgrade to Kix {} changes how stored data is kept, and no one has acknowledged it ({}).",
        state.to,
        state::FILE
    );
    for d in &open {
        text.push_str(&format!(
            "\n\n[{}] Kix {}:\n{}",
            d.reference, d.release, d.body
        ));
    }
    text.push_str(&format!(
        "\n\nRead each change, then run `kix upgrade --ack {}` and deploy again.",
        open.iter()
            .map(|d| d.reference.as_str())
            .collect::<Vec<_>>()
            .join(" ")
    ));
    Err(miette!("{text}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_exact_prerelease_in_kix_toml_is_the_version_the_project_uses() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("kix.toml"), "kix = \"0.8.0-rc.1\"\n").unwrap();
        let config = kix::project::ProjectConfig::read(Some(dir.path()), None).unwrap();
        let v = current_version(dir.path(), &config).unwrap();
        assert_eq!(v.release(), "0.8.0-rc.1");
        assert!(v < "0.8.0".parse().unwrap());
    }
}
