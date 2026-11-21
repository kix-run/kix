//! Work out the steps from the baseline to the goal, and where a stopped run
//! goes on from.

use kix::release::{self, Source};
use kix::version::Version;
use miette::{Result, miette};

use super::choose::Chosen;
use super::halt::Flow;
use super::plan::{self, ReleaseRecords};
use super::state::{self, Step};
use super::subject::Subject;

/// The way from the baseline to the goal, and the change records on it.
pub(super) struct Route {
    /// The version the upgrade started from, whose builds it compares
    /// against.
    pub(super) from: Version,
    /// The version the person asked for.
    pub(super) target: Version,
    /// What `kix-upgrade.json` records as asked for.
    pub(super) requested: String,
    /// Where this run ends: `target`, or the release a required stop ends
    /// the upgrade at.
    pub(super) goal: Version,
    /// The release that asks clusters to deploy it first, and `goal`.
    pub(super) stop: Option<(Version, Version)>,
    /// The versions a stepping upgrade takes, ending at `goal`.
    pub(super) steps: Vec<Version>,
    pub(super) records: Vec<ReleaseRecords>,
    /// The releases on the way that shipped no change records.
    pub(super) without_notes: Vec<String>,
}

/// Fetch the change records between `from` and `target`, and work out
/// where the upgrade stops and the steps it takes.
pub(super) fn plan_route(
    chosen: &Chosen,
    from: Version,
    target: Version,
    requested: String,
) -> Flow<Route> {
    let index = chosen
        .index
        .as_ref()
        .expect("a decision to proceed reads the release index");
    let releases = plan::usable(&index.releases, &chosen.system);
    let (records, without_notes) = fetch_records(&chosen.source, &index.releases, &from, &target)?;
    let stop = plan::required_stop(&releases, &records, &from, &target);
    let goal = stop
        .as_ref()
        .map_or(target.clone(), |(_, until)| until.clone());
    let steps = plan::steps(&releases, &from, &goal);
    Ok(Route {
        from,
        target,
        requested,
        goal,
        stop,
        steps,
        records,
        without_notes,
    })
}

/// Where the steps of an upgrade go on from.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Walk {
    /// Try the goal straight away, and step one minor at a time if it fails.
    Jump,
    /// Take these steps in turn.
    Through(Vec<Version>),
}

/// Return how an upgrade along `steps` to `goal` goes on, given the steps a
/// stopped run `recorded`. A last step that did not finish is taken again.
pub(super) fn walk_from(recorded: &[Step], steps: &[Version], goal: &Version) -> Result<Walk> {
    let Some(last) = recorded.last() else {
        return Ok(Walk::Jump);
    };
    let at: Version = last
        .version
        .parse()
        .map_err(|_| miette!("{} names no version in its last step", state::FILE))?;
    let done = last.result == "ok";
    let remaining: Vec<Version> = steps
        .iter()
        .filter(|v| if done { **v > at } else { **v >= at })
        .cloned()
        .collect();
    // A first try of the goal that failed is a jump again.
    let first_try = !done && recorded.len() == 1 && &at == goal;
    if remaining.is_empty() || first_try {
        Ok(Walk::Jump)
    } else {
        Ok(Walk::Through(remaining))
    }
}

/// Return the lines that say where an upgrade of `subject` along `steps` to
/// `goal` stopped when the build at `failing` failed.
pub(super) fn stopped_lines(
    subject: &Subject,
    failing: &Version,
    goal: &Version,
    steps: &[Version],
) -> Vec<String> {
    let command = subject.command();
    let position = steps.iter().position(|v| v == failing).map_or(1, |i| i + 1);
    if failing != goal {
        return vec![
            format!(
                "Stopped at Kix {} (step {position} of {} toward {}).",
                failing.release(),
                steps.len(),
                goal.release()
            ),
            format!(
                "{} so you can fix this step first.",
                subject.left_on(failing)
            ),
            format!(
                "Next: fix the error above, then run `{command}` to continue to {}.",
                goal.release()
            ),
        ];
    }
    let stopped = if steps.len() == 1 {
        format!("Stopped at Kix {}.", goal.release())
    } else {
        format!(
            "Stopped at Kix {} (step {position} of {}).",
            goal.release(),
            steps.len()
        )
    };
    vec![
        stopped,
        format!("{} so you can fix the build.", subject.left_on(goal)),
        format!("Next: fix the error above, then run `{command}` to finish the upgrade."),
    ]
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

#[cfg(test)]
mod tests {
    use super::*;

    fn v(text: &str) -> Version {
        text.parse().unwrap()
    }

    fn step(version: &str, result: &str) -> Step {
        Step {
            version: version.into(),
            result: result.into(),
            failed: Vec::new(),
        }
    }

    #[test]
    fn the_steps_go_on_from_where_a_stopped_run_was() {
        let steps = [v("0.9.2"), v("0.10.1"), v("0.11.0")];
        let goal = v("0.11.0");
        let walk = |recorded: &[Step]| walk_from(recorded, &steps, &goal).unwrap();
        // A new run tries the goal first.
        assert_eq!(walk(&[]), Walk::Jump);
        // The first try of the goal failed, so it is tried again.
        assert_eq!(walk(&[step("0.11.0", "failed")]), Walk::Jump);
        // A stepping run that failed at a step takes it again.
        assert_eq!(
            walk(&[
                step("0.11.0", "failed"),
                step("0.9.2", "ok"),
                step("0.10.1", "failed")
            ]),
            Walk::Through(vec![v("0.10.1"), v("0.11.0")])
        );
        // A step that built goes on to the next one.
        assert_eq!(
            walk(&[step("0.11.0", "failed"), step("0.9.2", "ok")]),
            Walk::Through(vec![v("0.10.1"), v("0.11.0")])
        );
        // An interrupted step is taken again.
        assert_eq!(
            walk(&[step("0.11.0", "failed"), step("0.10.1", "started")]),
            Walk::Through(vec![v("0.10.1"), v("0.11.0")])
        );
        // Nothing is left past the last step that built.
        assert_eq!(walk(&[step("0.11.0", "ok")]), Walk::Jump);
        assert!(walk_from(&[step("next", "ok")], &steps, &goal).is_err());
    }

    #[test]
    fn a_failed_step_says_where_the_upgrade_stopped() {
        let steps = [v("0.10.1"), v("0.11.0")];
        let kix = Subject::Input {
            name: "kix".into(),
            clusters: None,
        };
        let stopped_lines = |failing: &Version, goal: &Version, steps: &[Version]| {
            stopped_lines(&kix, failing, goal, steps)
        };
        let lines = stopped_lines(&v("0.10.1"), &v("0.11.0"), &steps);
        assert_eq!(
            lines[0],
            "Stopped at Kix 0.10.1 (step 1 of 2 toward 0.11.0)."
        );
        assert!(lines[2].ends_with("to continue to 0.11.0."), "{lines:?}");
        let lines = stopped_lines(&v("0.11.0"), &v("0.11.0"), &steps);
        assert_eq!(lines[0], "Stopped at Kix 0.11.0 (step 2 of 2).");
        assert!(lines[2].ends_with("to finish the upgrade."), "{lines:?}");
        let lines = stopped_lines(&v("0.11.0"), &v("0.11.0"), &[v("0.11.0")]);
        assert_eq!(lines[0], "Stopped at Kix 0.11.0.");
        assert_eq!(
            lines[1],
            "flake.nix and flake.lock are pinned to 0.11.0 so you can fix the build."
        );
        let prod = Subject::Cluster {
            cluster: "prod".into(),
            from: "kix-stable".into(),
            to: "kix".into(),
        };
        let lines = super::stopped_lines(&prod, &v("0.11.0"), &v("0.11.0"), &[v("0.11.0")]);
        assert_eq!(
            lines[1],
            "kix.toml lists the cluster `prod` under `kix` (Kix 0.11.0) so you can fix the build."
        );
        assert_eq!(
            lines[2],
            "Next: fix the error above, then run `kix upgrade prod --to kix` to finish the upgrade."
        );
    }
}
