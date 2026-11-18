//! Which version `kix upgrade` moves a project to, decided in one place.
//!
//! [`decide`] reads where the project stands and what the person asked for,
//! and returns a [`Decision`]. The caller only acts on it and prints it. The
//! rule that a target must be newer is [`judge_upgrade`].

use chrono::NaiveDate;
use kix::release::index::Release;
use kix::version::Version;
use kix::version::policy::{Requirement, UpgradeVerdict, judge_upgrade};

use super::plan;

/// The `requested` value of an upgrade that asked for the latest release.
pub const LATEST: &str = "latest";

/// A stopped upgrade that this run goes on with.
#[derive(Debug, Clone)]
pub struct Resume {
    /// The version the stopped run started from, whose builds it compares
    /// against.
    pub baseline: Version,
    /// The `--to` value the stopped run started with, or [`LATEST`]. `None`
    /// when a Kix that did not record it wrote the state.
    pub requested: Option<String>,
    /// The version the stopped run was moving the project to.
    pub goal: String,
}

/// What [`decide`] reads.
#[derive(Debug, Clone)]
pub struct Ask<'a> {
    /// The version `flake.lock` pins, or `None` when it pins no release.
    pub pinned: Option<&'a Version>,
    pub resume: Option<&'a Resume>,
    /// The `--to` value of this run.
    pub to: Option<&'a str>,
    pub system: &'a str,
    /// `min-age` in kix.toml, in days.
    pub min_age: Option<u32>,
    pub today: NaiveDate,
}

/// What `kix upgrade` does about its target.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// Move the project from `from`, the baseline, to `target`. `requested`
    /// is what the state records, so a resume asks for the same thing.
    Proceed {
        from: Version,
        target: Version,
        requested: String,
    },
    /// The project pins no release, so Kix only pins this version.
    PinOnly(Version),
    /// The project on `from` has nothing newer to move to. `target` is the
    /// release Kix chose.
    NothingToDo {
        from: Version,
        target: Version,
        to: Option<Requirement>,
    },
    /// The target is older than the version the project is pinned to.
    RefuseOlder { pinned: Version, target: Version },
    /// A resumed run's target is the version it started from.
    ResumeNotNewer { from: Version, target: Version },
    /// No release matches the request.
    NoRelease { to: Option<Requirement> },
    /// `--to` names no version.
    InvalidTo(String),
    /// A resumed run without `--to` cannot tell what the stopped run asked
    /// for. `goal` is where the stopped run was going.
    ResumeNeedsTo { goal: String },
    /// The answer depends on the release index. Call [`decide`] again with
    /// it.
    NeedsReleases,
}

/// Decide the target of an upgrade. `releases` is the release index, or
/// `None` before Kix has fetched it. A decision that needs it is
/// [`Decision::NeedsReleases`], so an exact version the project is on, or
/// an older one, needs no network.
pub fn decide(ask: &Ask, releases: Option<&[Release]>) -> Decision {
    let requested = match (ask.to, ask.resume) {
        (Some(to), _) => to.to_string(),
        (None, None) => LATEST.to_string(),
        (None, Some(resume)) => match &resume.requested {
            Some(requested) => requested.clone(),
            None => {
                return Decision::ResumeNeedsTo {
                    goal: resume.goal.clone(),
                };
            }
        },
    };
    let to = if requested == LATEST {
        None
    } else {
        match requested.parse::<Requirement>() {
            Ok(req) => Some(req),
            Err(_) => return Decision::InvalidTo(requested),
        }
    };
    let Some(pinned) = ask.pinned else {
        return match (to, releases) {
            (Some(Requirement::Exact(v)), _) => Decision::PinOnly(v),
            (to, Some(releases)) => match choose(ask, &to, releases) {
                Some(target) => Decision::PinOnly(target),
                None => Decision::NoRelease { to },
            },
            (_, None) => Decision::NeedsReleases,
        };
    };
    let baseline = ask.resume.map_or(pinned, |r| &r.baseline);

    // An exact version needs the index only when it is newer, to check that
    // it was released.
    if let Some(Requirement::Exact(v)) = &to {
        let decision = judge(ask, pinned, baseline, v, &to, &requested);
        if !matches!(decision, Decision::Proceed { .. }) {
            return decision;
        }
    }
    let Some(releases) = releases else {
        return Decision::NeedsReleases;
    };
    match choose(ask, &to, releases) {
        Some(target) => judge(ask, pinned, baseline, &target, &to, &requested),
        None => Decision::NoRelease { to },
    }
}

/// Return the release that matches `to` in `releases`, the newest one when
/// `to` is `None`. A prerelease is a target only when `to` names it in full.
fn choose(ask: &Ask, to: &Option<Requirement>, releases: &[Release]) -> Option<Version> {
    let on_system = |r: &&Release| r.systems.iter().any(|s| s == ask.system);
    if let Some(Requirement::Exact(v)) = to
        && v.is_prerelease()
    {
        return releases
            .iter()
            .filter(on_system)
            .find(|r| r.version == *v)
            .map(|r| r.version.clone());
    }
    let usable = plan::usable(releases, ask.system);
    plan::choose_target(&usable, to.as_ref(), ask.min_age, ask.today)
}

/// Turn the verdict of [`judge_upgrade`] on `target` into a decision.
fn judge(
    ask: &Ask,
    pinned: &Version,
    baseline: &Version,
    target: &Version,
    to: &Option<Requirement>,
    requested: &str,
) -> Decision {
    let resuming = ask.resume.is_some();
    match judge_upgrade(pinned, baseline, target) {
        UpgradeVerdict::Proceed => Decision::Proceed {
            from: baseline.clone(),
            target: target.clone(),
            requested: requested.to_string(),
        },
        UpgradeVerdict::AlreadyThere if resuming => Decision::ResumeNotNewer {
            from: baseline.clone(),
            target: target.clone(),
        },
        // Without a request, the newest release can be older than a project
        // on a prerelease or on a release younger than `min-age`.
        UpgradeVerdict::AlreadyThere | UpgradeVerdict::Older if !resuming && to.is_none() => {
            Decision::NothingToDo {
                from: pinned.clone(),
                target: target.clone(),
                to: None,
            }
        }
        UpgradeVerdict::AlreadyThere => Decision::NothingToDo {
            from: pinned.clone(),
            target: target.clone(),
            to: to.clone(),
        },
        UpgradeVerdict::Older => Decision::RefuseOlder {
            pinned: pinned.clone(),
            target: target.clone(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::upgrade::plan::required_stop;
    use crate::commands::upgrade::plan::tests::{doc, record};

    fn v(text: &str) -> Version {
        text.parse().unwrap()
    }

    fn release(version: &str) -> Release {
        Release {
            version: v(version),
            systems: vec!["x86_64-linux".into()],
            sums: String::new(),
            signature: None,
            download: String::new(),
            date: Some("2026-01-01".into()),
        }
    }

    fn index() -> Vec<Release> {
        ["0.9.1", "0.9.2", "0.10.0-rc.3", "0.10.0-rc.4"]
            .into_iter()
            .map(release)
            .collect()
    }

    fn ask<'a>(
        pinned: Option<&'a Version>,
        resume: Option<&'a Resume>,
        to: Option<&'a str>,
    ) -> Ask<'a> {
        Ask {
            pinned,
            resume,
            to,
            system: "x86_64-linux",
            min_age: None,
            today: NaiveDate::from_ymd_opt(2026, 11, 14).unwrap(),
        }
    }

    /// Decide as `kix upgrade` does: without the index first, then with it
    /// when the decision needs it.
    fn decide_with(ask: &Ask, releases: &[Release]) -> Decision {
        match decide(ask, None) {
            Decision::NeedsReleases => decide(ask, Some(releases)),
            decision => decision,
        }
    }

    fn proceed(from: &str, target: &str, requested: &str) -> Decision {
        Decision::Proceed {
            from: v(from),
            target: v(target),
            requested: requested.into(),
        }
    }

    fn resume(baseline: &str, requested: Option<&str>, goal: &str) -> Resume {
        Resume {
            baseline: v(baseline),
            requested: requested.map(str::to_string),
            goal: goal.into(),
        }
    }

    #[test]
    fn a_new_run_goes_to_the_latest_release_and_records_that() {
        let pinned = v("0.9.1");
        assert_eq!(
            decide_with(&ask(Some(&pinned), None, None), &index()),
            proceed("0.9.1", "0.9.2", LATEST)
        );
        let pinned = v("0.9.2");
        assert_eq!(
            decide_with(&ask(Some(&pinned), None, None), &index()),
            Decision::NothingToDo {
                from: v("0.9.2"),
                target: v("0.9.2"),
                to: None
            }
        );
    }

    #[test]
    fn a_prerelease_is_a_target_only_when_named_in_full() {
        let pinned = v("0.9.2");
        assert_eq!(
            decide_with(&ask(Some(&pinned), None, Some("0.10.0-rc.4")), &index()),
            proceed("0.9.2", "0.10.0-rc.4", "0.10.0-rc.4")
        );
        assert_eq!(
            decide_with(&ask(Some(&pinned), None, Some("0.10")), &index()),
            Decision::NoRelease {
                to: Some("0.10".parse().unwrap())
            }
        );
        // The latest release is older than a project on a prerelease.
        let pinned = v("0.10.0-rc.4");
        assert_eq!(
            decide_with(&ask(Some(&pinned), None, None), &index()),
            Decision::NothingToDo {
                from: v("0.10.0-rc.4"),
                target: v("0.9.2"),
                to: None
            }
        );
    }

    #[test]
    fn an_older_target_is_refused_and_an_exact_one_needs_no_index() {
        let pinned = v("0.10.0-rc.4");
        let refused = Decision::RefuseOlder {
            pinned: v("0.10.0-rc.4"),
            target: v("0.9.2"),
        };
        assert_eq!(
            decide(&ask(Some(&pinned), None, Some("0.9.2")), None),
            refused
        );
        assert_eq!(
            decide_with(&ask(Some(&pinned), None, Some("0.9")), &index()),
            refused
        );
        assert_eq!(
            decide(&ask(Some(&pinned), None, Some("0.10.0-rc.4")), None),
            Decision::NothingToDo {
                from: v("0.10.0-rc.4"),
                target: v("0.10.0-rc.4"),
                to: Some("0.10.0-rc.4".parse().unwrap())
            }
        );
        assert_eq!(
            decide(&ask(Some(&pinned), None, Some("next")), None),
            Decision::InvalidTo("next".into())
        );
    }

    #[test]
    fn a_resume_asks_for_what_the_stopped_run_asked_for() {
        // The stopped run pinned the prerelease it was asked for, and its
        // build failed.
        let pinned = v("0.10.0-rc.4");
        let r = resume("0.9.2", Some("0.10.0-rc.4"), "0.10.0-rc.4");
        assert_eq!(
            decide_with(&ask(Some(&pinned), Some(&r), None), &index()),
            proceed("0.9.2", "0.10.0-rc.4", "0.10.0-rc.4")
        );
        // `--to` on the resume replaces the request.
        assert_eq!(
            decide_with(&ask(Some(&pinned), Some(&r), Some("latest")), &index()),
            Decision::RefuseOlder {
                pinned: v("0.10.0-rc.4"),
                target: v("0.9.2")
            }
        );
        // A resume that asked for the latest release.
        let pinned = v("0.9.1");
        let r = resume("0.9.1", Some(LATEST), "0.9.2");
        assert_eq!(
            decide_with(&ask(Some(&pinned), Some(&r), None), &index()),
            proceed("0.9.1", "0.9.2", LATEST)
        );
    }

    #[test]
    fn a_resume_without_a_recorded_request_needs_to() {
        // An older Kix wrote the state without `requested`. Aiming at the
        // latest release would move this project from 0.10.0-rc.4 back to
        // 0.9.2.
        let pinned = v("0.10.0-rc.4");
        let r = resume("0.9.2", None, "0.10.0-rc.4");
        assert_eq!(
            decide(&ask(Some(&pinned), Some(&r), None), None),
            Decision::ResumeNeedsTo {
                goal: "0.10.0-rc.4".into()
            }
        );
        assert_eq!(
            decide_with(&ask(Some(&pinned), Some(&r), Some("0.10.0-rc.4")), &index()),
            proceed("0.9.2", "0.10.0-rc.4", "0.10.0-rc.4")
        );
    }

    #[test]
    fn a_resume_at_its_baseline_has_nowhere_to_go() {
        let pinned = v("0.9.2");
        let r = resume("0.9.2", Some(LATEST), "0.10.0");
        assert_eq!(
            decide_with(&ask(Some(&pinned), Some(&r), None), &index()),
            Decision::ResumeNotNewer {
                from: v("0.9.2"),
                target: v("0.9.2")
            }
        );
    }

    #[test]
    fn a_project_with_no_pin_is_only_pinned() {
        assert_eq!(
            decide(&ask(None, None, Some("0.9.1")), None),
            Decision::PinOnly(v("0.9.1"))
        );
        assert_eq!(
            decide(&ask(None, None, None), None),
            Decision::NeedsReleases
        );
        assert_eq!(
            decide(&ask(None, None, None), Some(&index())),
            Decision::PinOnly(v("0.9.2"))
        );
    }

    #[test]
    fn a_required_stop_cuts_the_target_short_on_every_run() {
        // The decision names the target the person asked for. The stop is
        // worked out from it again on each run, so a resume does not skip
        // it.
        let mut all = index();
        all.push(release("0.10.0"));
        all.push(release("0.10.1"));
        all.push(release("0.11.0"));
        let usable = plan::usable(&all, "x86_64-linux");
        let stop = record(
            "move-records",
            "+++\nkind = \"note\"\nstate = true\nrequired-stop = true\n+++\nMoved.\n",
        );
        let records = vec![doc("0.10.0", vec![stop])];
        let pinned = v("0.10.0");
        let r = resume("0.9.2", Some(LATEST), "0.10.1");
        let Decision::Proceed { from, target, .. } =
            decide_with(&ask(Some(&pinned), Some(&r), None), &all)
        else {
            panic!("the resume proceeds");
        };
        assert_eq!(target, v("0.11.0"));
        assert_eq!(
            required_stop(&usable, &records, &from, &target),
            Some((v("0.10.0"), v("0.10.1")))
        );
    }
}
