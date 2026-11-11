//! Required stops: releases every cluster must deploy before it moves to a
//! newer minor, because they change what Kix stores in the cluster.

use kix::version::Version;

/// The releases every cluster must deploy before it moves past their minor.
/// The release skill adds a version here when one of the release's change
/// records has `required-stop = true`.
pub const REQUIRED_STOPS: &[&str] = &[];

/// Return the required stop a deploy with Kix `running` would skip, for a
/// cluster Kix `last` deployed last: the oldest stop newer than `last`
/// whose minor is older than `running`'s. A deploy with a Kix of the stop's
/// own minor makes the stop.
pub fn skipped(last: &Version, running: &Version, stops: &[Version]) -> Option<Version> {
    stops
        .iter()
        .filter(|s| last < *s && running.minor_key() > s.minor_key())
        .min()
        .cloned()
}

/// Refuse the deploy of `cluster`, which Kix `last` deployed last, when it
/// would skip a required stop. Print why and exit 1.
pub fn check(cluster: &str, last: &str) {
    let Ok(last) = last.parse::<Version>() else {
        return;
    };
    let stops: Vec<Version> = REQUIRED_STOPS
        .iter()
        .map(|s| s.parse().expect("REQUIRED_STOPS holds versions"))
        .collect();
    let running = kix::version::running();
    let Some(stop) = skipped(&last, running, &stops) else {
        return;
    };
    let (last, stop_minor, running) = (last.release(), stop.minor_text(), running.release());
    let stop = stop.release();
    eprintln!(
        "Deploy blocked: cluster {cluster} was last deployed with Kix {last}, and cannot skip required stop Kix {stop} on the way to Kix {running}."
    );
    eprintln!("Nothing was applied to cluster {cluster}.");
    eprintln!();
    eprintln!(
        "Every cluster deployed with Kix older than {stop} must be deployed once with Kix {stop_minor}.x before deploying Kix {running}."
    );
    eprintln!();
    eprintln!(
        "Next: check out the commit where this project was pinned to Kix {stop_minor}.x (for example with `git worktree add` or `git checkout`), run `kix deploy {cluster}` from there, then return here and run `kix deploy {cluster}` again."
    );
    std::process::exit(1);
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
    fn the_built_in_stops_are_versions() {
        for s in REQUIRED_STOPS {
            assert!(s.parse::<Version>().is_ok(), "{s}");
        }
    }
}
