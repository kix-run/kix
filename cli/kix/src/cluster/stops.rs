//! Required stops: releases every cluster must deploy before it moves to a
//! newer minor, because they change what Kix stores in the cluster.
//!
//! Every program that writes a deploy into a cluster calls [`check`] before
//! it applies anything: `kix deploy`, `kix rollback`, and the operator.

use std::fmt;

use crate::version::Version;

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

/// Refuse a deploy with Kix `running` of a cluster that Kix `last` deployed
/// last, when it would skip one of `stops`. `last` comes from the cluster's
/// deploy receipt. A cluster with no receipt, or one whose version does not
/// parse, passes.
pub fn check(
    last: Option<&str>,
    running: &Version,
    stops: &[Version],
) -> Result<(), Box<SkippedStop>> {
    let Some(last) = last.and_then(|l| l.parse::<Version>().ok()) else {
        return Ok(());
    };
    match skipped(&last, running, stops) {
        Some(stop) => Err(Box::new(SkippedStop {
            last,
            stop,
            running: running.clone(),
        })),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(s: &str) -> Version {
        s.parse().unwrap()
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
        let refusal = check(Some("0.10.0"), &v("0.12.1"), &stops).unwrap_err();
        assert_eq!(
            *refusal,
            SkippedStop {
                last: v("0.10.0"),
                stop: v("0.11.0"),
                running: v("0.12.1"),
            }
        );
        assert!(
            refusal
                .to_string()
                .contains("Deploy the cluster once with Kix 0.11.x"),
            "{refusal}"
        );
        assert_eq!(check(Some("0.11.0"), &v("0.12.1"), &stops), Ok(()));
    }

    #[test]
    fn a_cluster_without_a_readable_receipt_passes() {
        let stops = [v("0.11.0")];
        assert_eq!(check(None, &v("0.12.1"), &stops), Ok(()));
        assert_eq!(check(Some("unknown"), &v("0.12.1"), &stops), Ok(()));
    }

    #[test]
    fn the_built_in_stops_are_versions() {
        for s in REQUIRED_STOPS {
            assert!(s.parse::<Version>().is_ok(), "{s}");
        }
        assert_eq!(required_stops().len(), REQUIRED_STOPS.len());
    }
}
