//! Compare the builds once every step built, and report what a person
//! should review.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use kix::changes::Kind;
use kix::version::Version;
use miette::{Result, miette};

use super::EXIT_NEEDS_PERSON;
use super::halt::Flow;
use super::plan::{self, Applying};
use super::route::Route;
use super::run::Run;
use super::state::{self, DataChange, Status};
use super::subject::Subject;
use super::{compare, out, search};
use crate::exit::Exit;

impl Run {
    /// Compare the builds, print the release notes and what a person should
    /// review, save the final state, and return how the run ends.
    pub(super) fn finish(&mut self, route: &Route, applying: &[Applying]) -> Flow<Exit> {
        let (from, goal) = (&route.from, &route.goal);
        let mut state = self.state.take().expect("the steps ran with a state");
        let report = report_changes(
            &self.work.join("before"),
            &self.work.join(goal.release()),
            from,
            goal,
        )?;
        state.sensitive_changes = report.sensitive;

        let notes = out::notes(applying, false, from, goal);
        if !notes.is_empty() {
            println!();
            println!("Release notes for this upgrade:");
            if let Some(legend) = out::legend(applying, None) {
                println!("{legend}");
            }
            for line in notes {
                println!("{line}");
            }
        }
        state.cli_hits = cli_hits(&self.dir, applying);
        self.prune(from, goal);

        state
            .acknowledged
            .retain(|a| state.data_changes.iter().any(|d| &d.reference == a));
        let mut items = report.review.items();
        for a in plan::of_kind(applying, Kind::Silent) {
            if !a.record.touches_data {
                items.push(out::silent_item(a));
            } else if !state.acknowledged.contains(&a.reference()) {
                items.push(out::data_item(a));
            }
        }
        state.status = finished_status(Findings {
            stop: route.stop.is_some(),
            changed: report.any_changed,
            sensitive: report.sensitive,
            silent: !plan::of_kind(applying, Kind::Silent).is_empty(),
            unacknowledged: !state.unacknowledged().is_empty(),
        });
        state.write(&self.dir).map_err(|e| miette!("{e}"))?;

        println!();
        let upgraded = match &self.subject {
            Subject::Input { .. } => format!("Upgraded to Kix {}", goal.release()),
            Subject::Cluster { cluster, to, .. } => format!(
                "Moved cluster `{cluster}` to Kix {} (input `{to}`)",
                goal.release()
            ),
        };
        if state.status == Status::Done {
            println!("{upgraded}. Ready to deploy.");
            return Ok(Exit::Success);
        }
        if let Some((r, _)) = &route.stop {
            items.push(vec![
                format!(
                    "Kix {} must be deployed to all clusters before continuing to {}",
                    r.release(),
                    route.target.release()
                ),
                format!(
                    "     (`kix deploy` on {} will refuse any cluster still on {}).",
                    route.target.release(),
                    from.release()
                ),
                format!(
                    "     flake.nix and flake.lock are pinned to {}.",
                    goal.release()
                ),
            ]);
        }
        println!("{upgraded}, but review before deploying:");
        for line in out::numbered(&items) {
            println!("{line}");
        }
        if route.stop.is_some() {
            println!(
                "Next: commit this {} step and deploy every cluster with `kix deploy <cluster>`, then run `kix upgrade` to continue to {}.",
                goal.release(),
                route.target.release()
            );
        }
        Ok(EXIT_NEEDS_PERSON)
    }
}

/// What an upgrade that built every step found.
#[derive(Debug, Clone, Copy, Default)]
struct Findings {
    /// A required stop ended the upgrade before the target.
    stop: bool,
    /// An object changed in some cluster.
    changed: bool,
    /// The changes to RBAC, Secrets, network policy, and TLS.
    sensitive: usize,
    /// A record changes behaviour or data with no error.
    silent: bool,
    /// A data migration no one has acknowledged.
    unacknowledged: bool,
}

/// Return how an upgrade that built every step ends.
fn finished_status(f: Findings) -> Status {
    if f.stop {
        Status::RequiredStop
    } else if f.changed || f.sensitive > 0 || f.silent || f.unacknowledged {
        Status::NeedsPerson
    } else {
        Status::Done
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
        report.sensitive += changes.iter().filter(|c| c.review.is_some()).count();
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
pub(super) fn by_kind(applying: &[Applying]) -> BTreeMap<String, Vec<String>> {
    let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for a in applying {
        out.entry(a.record.kind.name().to_string())
            .or_default()
            .push(a.reference());
    }
    out
}

/// Return the applying records that change stored data with no error.
pub(super) fn data_changes(applying: &[Applying]) -> Vec<DataChange> {
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

/// Search the project's tracked files in `dir` for the commands and flags
/// the `applying` records change, and print what matched.
fn cli_hits(dir: &Path, applying: &[Applying]) -> Vec<state::CliHit> {
    let needles: Vec<String> = applying
        .iter()
        .flat_map(|a| a.record.cli.iter().cloned())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if needles.is_empty() {
        return Vec::new();
    }
    let Some(files) = search::tracked(dir) else {
        println!();
        println!(
            "Note: skipped searching project files for changed commands or flags (not a git repository)."
        );
        return Vec::new();
    };
    let hits = search::search(dir, &files, &needles);
    if !hits.is_empty() {
        println!();
        println!("Project files matching changed commands or flags:");
        for hit in &hits {
            println!("  {}:{}: {}", hit.file, hit.line, hit.text);
        }
    }
    hits
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_finished_upgrade_needs_a_person_for_any_finding() {
        let none = Findings::default();
        assert_eq!(finished_status(none), Status::Done);
        for f in [
            Findings {
                changed: true,
                ..none
            },
            Findings {
                sensitive: 1,
                ..none
            },
            Findings {
                silent: true,
                ..none
            },
            Findings {
                unacknowledged: true,
                ..none
            },
        ] {
            assert_eq!(finished_status(f), Status::NeedsPerson, "{f:?}");
        }
        let stop = Findings {
            stop: true,
            changed: true,
            ..none
        };
        assert_eq!(finished_status(stop), Status::RequiredStop);
    }
}
