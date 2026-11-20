//! Which Kix may deploy a cluster, given the Kix that deployed it last.
//!
//! Required stops are releases every cluster must deploy before it moves to
//! a newer minor, because they change what Kix stores in the cluster. A Kix
//! of an older minor than the last deploy's may not deploy at all, because it
//! may not read what the newer Kix stored.
//!
//! Every program that writes a deploy into a cluster calls [`check`] before
//! it applies anything: `kix deploy`, `kix rollback`, and the operator.

use std::fmt;

use crate::cluster::activation::Record;
use crate::version::Version;

/// The variable that lets an older minor of Kix deploy a cluster anyway, for
/// someone who must leave a bad newer release. Its value must be the version
/// that made the cluster's last deploy, so the setting fits one cluster state.
pub const ALLOW_DOWNGRADE_VAR: &str = "KIX_ALLOW_DOWNGRADE";

/// The releases every cluster must deploy before it moves past their minor.
/// The release skill adds a version here when one of the release's change
/// records has `required-stop = true`.
pub const REQUIRED_STOPS: &[&str] = &[];

/// Return [`REQUIRED_STOPS`] as versions.
pub fn required_stops() -> Vec<Version> {
    REQUIRED_STOPS
        .iter()
        .map(|s| s.parse().expect("REQUIRED_STOPS holds versions"))
        .collect()
}

/// A deploy refused because it would skip a required stop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkippedStop {
    /// The Kix that made the cluster's last deploy.
    pub last: Version,
    /// The oldest required stop the deploy would skip.
    pub stop: Version,
    /// The Kix that would make this deploy.
    pub running: Version,
}

impl fmt::Display for SkippedStop {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "the cluster was last deployed with Kix {last}, and Kix {running} cannot skip required stop Kix {stop}. \
             Nothing was applied. Deploy the cluster once with Kix {minor}.x, then deploy again with Kix {running}.",
            last = self.last.release(),
            running = self.running.release(),
            stop = self.stop.release(),
            minor = self.stop.minor_text(),
        )
    }
}

impl std::error::Error for SkippedStop {}

/// A deploy refused because a newer minor of Kix made the cluster's last
/// deploy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OlderKix {
    /// The Kix that made the cluster's last deploy.
    pub last: Version,
    /// The commit the last deploy was built from, when its receipt names one.
    pub commit: Option<String>,
    /// The Kix that would make this deploy.
    pub running: Version,
}

impl OlderKix {
    /// Return the last deploy's commit shortened to 7 characters, as Git
    /// prints it.
    pub fn short_commit(&self) -> Option<&str> {
        self.commit.as_deref().map(|c| c.get(..7).unwrap_or(c))
    }

    /// Return the text that names the last deploy, such as `Kix 0.9.1 (from
    /// commit abc1234)`.
    pub fn last_deploy(&self) -> String {
        match self.short_commit() {
            Some(commit) => format!("Kix {} (from commit {commit})", self.last.release()),
            None => format!("Kix {}", self.last.release()),
        }
    }
}

impl fmt::Display for OlderKix {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "the cluster was last deployed with {last}, and Kix {running} cannot deploy a cluster that a newer minor of Kix deployed. \
             Nothing was applied. Deploy with Kix {minor} or newer.",
            last = self.last_deploy(),
            running = self.running.release(),
            minor = self.last.minor_text(),
        )
    }
}

impl std::error::Error for OlderKix {}

/// A deploy refused because of the Kix that would make it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    SkippedStop(SkippedStop),
    OlderKix(OlderKix),
}

impl Refusal {
    /// Return the reason the operator records in its Warning event.
    pub fn event_reason(&self) -> &'static str {
        match self {
            Refusal::SkippedStop(_) => "RequiredStopSkipped",
            Refusal::OlderKix(_) => "OlderKix",
        }
    }
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::SkippedStop(r) => r.fmt(f),
            Refusal::OlderKix(r) => r.fmt(f),
        }
    }
}

impl std::error::Error for Refusal {}

/// Return the refusal of a deploy with Kix `running`, when the last deploy
/// in `active` was made by a newer minor of Kix. A record without a
/// version, or with one that does not parse, says nothing.
pub fn older_kix(active: Option<&Record>, running: &Version) -> Option<OlderKix> {
    let active = active?;
    let last = last_version(active)?;
    (last.minor_key() > running.minor_key()).then(|| OlderKix {
        last,
        commit: active.deployed_from.clone(),
        running: running.clone(),
    })
}

/// Return whether [`ALLOW_DOWNGRADE_VAR`], set to `allow`, lets `refusal`
/// through.
pub fn downgrade_allowed(refusal: &OlderKix, allow: Option<&str>) -> bool {
    allow.map(str::trim) == Some(refusal.last.release().as_str())
}

fn last_version(active: &Record) -> Option<Version> {
    active.deployed_with.as_deref()?.parse().ok()
}

/// Return the required stop a deploy with Kix `running` would skip, for a
/// cluster Kix `last` deployed last. That is the oldest stop newer than
/// `last` whose minor is older than `running`'s. A deploy with a Kix of the
/// stop's own minor makes the stop.
pub fn skipped(last: &Version, running: &Version, stops: &[Version]) -> Option<Version> {
    stops
        .iter()
        .filter(|s| last < *s && running.minor_key() > s.minor_key())
        .min()
        .cloned()
}

/// Refuse a deploy with Kix `running` of a cluster whose Active record is
/// `active`, when it would skip one of `stops` or when a newer minor of Kix
/// made the last deploy. The version of the last deploy comes from the
/// record's receipt. A cluster with no Active record, no receipt, or a
/// version that does not parse, passes.
pub fn check(
    active: Option<&Record>,
    running: &Version,
    stops: &[Version],
) -> Result<(), Box<Refusal>> {
    if let Some(refusal) = older_kix(active, running) {
        return Err(Box::new(Refusal::OlderKix(refusal)));
    }
    let Some(last) = active.and_then(last_version) else {
        return Ok(());
    };
    match skipped(&last, running, stops) {
        Some(stop) => Err(Box::new(Refusal::SkippedStop(SkippedStop {
            last,
            stop,
            running: running.clone(),
        }))),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(s: &str) -> Version {
        s.parse().unwrap()
    }

    fn deployed(version: Option<&str>, commit: Option<&str>) -> Record {
        Record {
            deployed_with: version.map(str::to_string),
            deployed_from: commit.map(str::to_string),
            ..Default::default()
        }
    }

    fn last(version: &str) -> Record {
        deployed(Some(version), None)
    }

    #[test]
    fn a_deploy_that_skips_a_stop_is_refused() {
        let stops = [v("0.11.0")];
        assert_eq!(
            skipped(&v("0.10.0"), &v("0.12.1"), &stops),
            Some(v("0.11.0"))
        );
        // A Kix of the stop's own minor makes the stop.
        assert_eq!(skipped(&v("0.10.0"), &v("0.11.2"), &stops), None);
        assert_eq!(skipped(&v("0.10.0"), &v("0.11.0"), &stops), None);
        // The cluster already ran the stop, or a newer release.
        assert_eq!(skipped(&v("0.11.0"), &v("0.12.1"), &stops), None);
        assert_eq!(skipped(&v("0.11.2"), &v("0.12.1"), &stops), None);
        assert_eq!(skipped(&v("0.12.0"), &v("0.12.1"), &stops), None);
        // A prerelease of the stop has not made it.
        assert_eq!(
            skipped(&v("0.11.0-rc.1"), &v("0.12.1"), &stops),
            Some(v("0.11.0"))
        );
    }

    #[test]
    fn the_oldest_skipped_stop_is_named() {
        let stops = [v("0.13.0"), v("0.11.0")];
        assert_eq!(
            skipped(&v("0.10.0"), &v("0.14.0"), &stops),
            Some(v("0.11.0"))
        );
        assert_eq!(
            skipped(&v("0.12.0"), &v("0.14.0"), &stops),
            Some(v("0.13.0"))
        );
        assert_eq!(skipped(&v("0.10.0"), &v("0.12.0"), &[]), None);
    }

    #[test]
    fn check_returns_the_refusal() {
        let stops = [v("0.11.0")];
        let refusal = check(Some(&last("0.10.0")), &v("0.12.1"), &stops).unwrap_err();
        assert_eq!(
            *refusal,
            Refusal::SkippedStop(SkippedStop {
                last: v("0.10.0"),
                stop: v("0.11.0"),
                running: v("0.12.1"),
            })
        );
        assert_eq!(refusal.event_reason(), "RequiredStopSkipped");
        assert!(
            refusal
                .to_string()
                .contains("Deploy the cluster once with Kix 0.11.x"),
            "{refusal}"
        );
        assert_eq!(check(Some(&last("0.11.0")), &v("0.12.1"), &stops), Ok(()));
    }

    #[test]
    fn a_cluster_without_a_readable_receipt_passes() {
        let stops = [v("0.11.0")];
        assert_eq!(check(None, &v("0.12.1"), &stops), Ok(()));
        assert_eq!(
            check(Some(&deployed(None, Some("abc"))), &v("0.12.1"), &stops),
            Ok(())
        );
        assert_eq!(check(Some(&last("unknown")), &v("0.12.1"), &stops), Ok(()));
        assert_eq!(check(Some(&last("unknown")), &v("0.8.0"), &stops), Ok(()));
    }

    #[test]
    fn a_deploy_by_an_older_minor_is_refused() {
        let active = deployed(Some("0.9.1"), Some("abc1234def5678"));
        let refusal = check(Some(&active), &v("0.8.4"), &[]).unwrap_err();
        assert_eq!(
            *refusal,
            Refusal::OlderKix(OlderKix {
                last: v("0.9.1"),
                commit: Some("abc1234def5678".into()),
                running: v("0.8.4"),
            })
        );
        assert_eq!(refusal.event_reason(), "OlderKix");
        assert_eq!(
            refusal.to_string(),
            "the cluster was last deployed with Kix 0.9.1 (from commit abc1234), and Kix 0.8.4 \
             cannot deploy a cluster that a newer minor of Kix deployed. Nothing was applied. \
             Deploy with Kix 0.9 or newer."
        );
        // A prerelease of the newer minor counts as that minor.
        assert!(older_kix(Some(&last("0.9.0-rc.1")), &v("0.8.4")).is_some());
        assert!(older_kix(Some(&last("1.0.0")), &v("0.12.0")).is_some());
    }

    #[test]
    fn only_the_last_version_named_allows_a_downgrade() {
        let refusal = older_kix(Some(&last("0.9.1+abc")), &v("0.8.4")).unwrap();
        assert!(downgrade_allowed(&refusal, Some("0.9.1")));
        assert!(downgrade_allowed(&refusal, Some(" 0.9.1\n")));
        assert!(!downgrade_allowed(&refusal, Some("0.9")));
        assert!(!downgrade_allowed(&refusal, Some("0.8.4")));
        assert!(!downgrade_allowed(&refusal, Some("1")));
        assert!(!downgrade_allowed(&refusal, None));
    }

    #[test]
    fn the_same_or_an_older_minor_may_be_deployed_over() {
        // An older patch of the same minor may deploy.
        assert_eq!(older_kix(Some(&last("0.9.3")), &v("0.9.1")), None);
        assert_eq!(older_kix(Some(&last("0.9.0")), &v("0.9.0-rc.2")), None);
        assert_eq!(older_kix(Some(&last("0.8.4")), &v("0.9.0")), None);
        assert_eq!(older_kix(None, &v("0.9.0")), None);
    }

    #[test]
    fn an_unknown_commit_is_left_out() {
        let refusal = older_kix(Some(&last("0.9.1")), &v("0.8.4")).unwrap();
        assert_eq!(refusal.last_deploy(), "Kix 0.9.1");
        let short = older_kix(Some(&deployed(Some("0.9.1"), Some("abc"))), &v("0.8.4")).unwrap();
        assert_eq!(short.last_deploy(), "Kix 0.9.1 (from commit abc)");
    }

    #[test]
    fn the_built_in_stops_are_versions() {
        for s in REQUIRED_STOPS {
            assert!(s.parse::<Version>().is_ok(), "{s}");
        }
        assert_eq!(required_stops().len(), REQUIRED_STOPS.len());
    }
}
