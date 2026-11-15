//! The phases of a run that build: the baseline, the steps, and the stop at
//! a step that failed.

use std::collections::BTreeSet;

use kix::changes::Kind;
use kix::version::Version;
use miette::miette;

use super::EXIT_BUILD_FAILED;
use super::finish::{by_kind, data_changes};
use super::halt::{Flow, Halt, refused};
use super::out::{self, Failed};
use super::plan::{self, Applying};
use super::preview::saved_in_use;
use super::route::{Route, Walk, stopped_lines, walk_from};
use super::run::{Failures, Outcome, Run};
use super::state::{self, Status, UpgradeState};
use super::subprocess::{clusters, packages_in_use};

/// The phases of a run, in the order [`super::upgrade`] calls them.
impl Run {
    /// Build the project as it is, with the version the upgrade starts from,
    /// and return the packages in use. A resumed run reuses the builds the
    /// stopped run cached instead, because after the first pin the version
    /// it started from can no longer evaluate the project.
    pub(super) fn baseline(
        &mut self,
        resume: Option<&UpgradeState>,
        route: &Route,
    ) -> Flow<Option<BTreeSet<String>>> {
        let (from, goal) = (&route.from, &route.goal);
        let before = self.work.join("before");
        if let Some(s) = resume {
            if s.before != before || !before.is_dir() {
                return Err(refused(format!(
                    "Cannot resume upgrade from Kix {from}: cached baseline builds were not found at {}.\nflake.nix and flake.lock remain at Kix {pinned}.\nNext: delete kix-upgrade.json and run `kix upgrade` to start a new comparison from Kix {pinned}.",
                    before.display(),
                    from = from.release(),
                    pinned = self.pinned.release()
                )));
            }
            // Name the pin only when the project is on a step between the
            // two ends; otherwise the next lines say what Kix does first.
            if &self.pinned != from && &self.pinned != goal {
                println!(
                    "Resuming upgrade Kix {} -> {} (from {}, reusing {} baseline)",
                    from.release(),
                    goal.release(),
                    self.pinned.release(),
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
            return Ok(saved_in_use(s));
        }

        println!("Upgrading Kix {} -> {}", from.release(), goal.release());
        if !route.without_notes.is_empty() {
            println!("{}", out::without_notes_line(&route.without_notes));
        }
        println!();
        let from_kix = self.kix(from)?;
        let names = clusters(&from_kix, &self.dir).map_err(|e| miette!("{e}"))?;
        if names.is_empty() {
            return Err(refused(format!(
                "Cannot upgrade: Kix {} found no clusters in this project.\nNo project files were modified.\nNext: add at least one cluster to the project, then run `kix upgrade` again.",
                from.release()
            )));
        }
        let in_use = packages_in_use(&from_kix, from, &self.dir);
        let built = self.build_all(&from_kix, from, &before);
        let failed: Vec<String> = built.failures.iter().map(|f| f.cluster.clone()).collect();
        println!(
            "{}",
            out::build_line(
                built.clusters.len(),
                from,
                true,
                Some(&built.clusters),
                (!failed.is_empty()).then_some(Failed::Count(&failed, built.clusters.len())),
            )
        );
        if failed.is_empty() {
            return Ok(in_use);
        }
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
        Err(Halt::Stopped(EXIT_BUILD_FAILED))
    }

    /// Write the state the steps start from. It is written before the first
    /// pin and after each step, so a project left pinned part of the way
    /// always has a state to resume from.
    pub(super) fn begin(
        &mut self,
        resume: Option<&UpgradeState>,
        route: &Route,
        applying: &[Applying],
        in_use: Option<&BTreeSet<String>>,
    ) -> Flow<()> {
        self.state = Some(UpgradeState {
            schema: state::SCHEMA.into(),
            from: route.from.release(),
            to: route.goal.release(),
            requested: Some(route.requested.clone()),
            status: Status::FixNeeded,
            steps: resume.map(|s| s.steps.clone()).unwrap_or_default(),
            records: by_kind(applying),
            data_changes: data_changes(applying),
            acknowledged: resume.map(|s| s.acknowledged.clone()).unwrap_or_default(),
            sensitive_changes: 0,
            cli_hits: Vec::new(),
            before: self.work.join("before"),
            packages_in_use: in_use.map(|p| p.iter().cloned().collect()),
        });
        self.save()
    }

    /// Pin and build the steps of `route`, going on from where a stopped
    /// run was.
    pub(super) fn walk(&mut self, route: &Route) -> Flow<Outcome> {
        let walk = walk_from(&self.state().steps, &route.steps, &route.goal)?;
        if self
            .state()
            .steps
            .last()
            .is_some_and(|last| last.result != "ok")
        {
            self.state_mut().steps.pop();
        }
        match walk {
            Walk::Jump => self.jump(&route.goal, &route.steps),
            Walk::Through(remaining) => self.step_through(&remaining),
        }
    }

    /// Print why the build at `failing` stopped the upgrade, save the state,
    /// and return the halt.
    pub(super) fn stopped_at(
        &mut self,
        route: &Route,
        failing: &Version,
        failures: &Failures,
        in_use: Option<&BTreeSet<String>>,
    ) -> Halt {
        print_failures(failures);
        let previous_step = route
            .steps
            .iter()
            .filter(|v| *v < failing)
            .max()
            .unwrap_or(&route.from);
        let matching: Vec<Applying> =
            plan::applying(&route.records, previous_step, failing, in_use)
                .into_iter()
                .filter(|a| a.record.kind == Kind::Error)
                .collect();
        print_matching(&matching, previous_step, failing);
        println!();
        for line in stopped_lines(failing, &route.goal, &route.steps) {
            println!("{line}");
        }
        self.state_mut().status = Status::FixNeeded;
        if let Err(halt) = self.save() {
            return halt;
        }
        self.prune(&route.from, failing);
        Halt::Stopped(EXIT_BUILD_FAILED)
    }
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
