//! Which Kix may deploy a cluster, given the Kix that deployed it last.
//!
//! Required stops are releases every cluster must deploy before it moves to
//! a newer minor, because they change what Kix stores in the cluster. A Kix
//! of an older minor than the last deploy's may not deploy at all, because it
//! may not read what the newer Kix stored.
//!
//! Every program that writes to a cluster calls [`check`] before it changes
//! anything: `kix deploy`, `kix rollback`, `kix gc`, and the operator.
//!
//! The Kix that wrote last is the head's `status.writer`
//! ([`crate::cluster::head`]) when the head names one, else the version in
//! the receipt of the current record, as on a cluster no Kix with the head
//! has written to yet.

use std::fmt;

use crate::cluster::activation::Record;
use crate::cluster::head::Writer;
use crate::version::Version;

/// The variable that lets an older minor of Kix deploy a cluster anyway, for
/// someone who must leave a bad newer release. Its value must be the version
/// that made the cluster's last deploy, so the setting fits one cluster state.
pub const ALLOW_DOWNGRADE_VAR: &str = "KIX_ALLOW_DOWNGRADE";

/// The releases every cluster must deploy before it moves past their minor.
/// The release skill adds a version here when one of the release's change
/// records has `required-stop = true`, and a test checks that the two agree.
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
            "the cluster was last deployed with {last}, and Kix {running} is older than Kix {minor}. \
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

/// The Kix that wrote to a cluster last, as the checks read it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LastWrite {
    /// Its version, as written. `None` when nothing names it.
    pub version: Option<String>,
    /// The commit of the current record's build, when that record was
    /// written by this version.
    pub commit: Option<String>,
}

impl LastWrite {
    /// Read the last writer from `writer`, the head's `status.writer`, when
    /// the head names one, else from the receipt of `active`, the current
    /// record.
    pub fn of(writer: Option<&Writer>, active: Option<&Record>) -> LastWrite {
        match writer {
            Some(writer) => LastWrite {
                version: Some(writer.version.clone()),
                commit: active
                    .filter(|a| a.deployed_with.as_deref() == Some(writer.version.as_str()))
                    .and_then(|a| a.deployed_from.clone()),
            },
            None => LastWrite {
                version: active.and_then(|a| a.deployed_with.clone()),
                commit: active.and_then(|a| a.deployed_from.clone()),
            },
        }
    }
}

/// Return the refusal of a write with Kix `running`, when `last` was made by
/// a newer minor of Kix. A version that is missing or does not parse says
/// nothing.
pub fn older_kix(last: &LastWrite, running: &Version) -> Option<OlderKix> {
    let version = last_version(last)?;
    (version.minor_key() > running.minor_key()).then(|| OlderKix {
        last: version,
        commit: last.commit.clone(),
        running: running.clone(),
    })
}

/// Return whether [`ALLOW_DOWNGRADE_VAR`], set to `allow`, lets `refusal`
/// through.
pub fn downgrade_allowed(refusal: &OlderKix, allow: Option<&str>) -> bool {
    allow.map(str::trim) == Some(refusal.last.release().as_str())
}

fn last_version(last: &LastWrite) -> Option<Version> {
    last.version.as_deref()?.parse().ok()
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

/// Refuse a write with Kix `running` to a cluster that `last` wrote to
/// last, when it would skip one of `stops` or when a newer minor of Kix
/// made the last write. A cluster whose last writer is unknown, or whose
/// version does not parse, passes.
pub fn check(last: &LastWrite, running: &Version, stops: &[Version]) -> Result<(), Box<Refusal>> {
    if let Some(refusal) = older_kix(last, running) {
        return Err(Box::new(Refusal::OlderKix(refusal)));
    }
    let Some(last) = last_version(last) else {
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

    fn record(version: Option<&str>, commit: Option<&str>) -> Record {
        Record {
            deployed_with: version.map(str::to_string),
            deployed_from: commit.map(str::to_string),
            ..Default::default()
        }
    }

    fn deployed(version: Option<&str>, commit: Option<&str>) -> LastWrite {
        LastWrite::of(None, Some(&record(version, commit)))
    }

    fn last(version: &str) -> LastWrite {
        deployed(Some(version), None)
    }

    /// `kix upgrade` stops at the releases whose change records set
    /// `required-stop = true`, and `kix deploy` refuses to skip the releases in
    /// [`REQUIRED_STOPS`]. The two must name the same releases.
    ///
    /// Walks up from `CARGO_MANIFEST_DIR` to the repository root, and is
    /// skipped when the records are not there, so a packaged crate still
    /// tests clean.
    #[test]
    fn required_stops_match_the_change_records() {
        let Some(root) = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .find(|p| p.join("changes/README.md").is_file())
        else {
            return;
        };
        let mut from_records = std::collections::BTreeSet::new();
        for release in std::fs::read_dir(root.join("changes")).unwrap() {
            let release = release.unwrap().path();
            let Some(version) = release
                .file_name()
                .and_then(|n| n.to_str())
                .and_then(|n| n.parse::<Version>().ok())
                .filter(|v| !v.is_prerelease())
            else {
                continue;
            };
            for record in std::fs::read_dir(&release).unwrap() {
                let text = std::fs::read_to_string(record.unwrap().path()).unwrap();
                let header = text
                    .strip_prefix("+++\n")
                    .and_then(|rest| rest.split_once("\n+++"))
                    .map_or("", |(header, _)| header);
                let header: toml::Table = toml::from_str(header).unwrap();
                if header.get("required-stop") == Some(&toml::Value::Boolean(true)) {
                    from_records.insert(version.clone());
                }
            }
        }
        let listed: std::collections::BTreeSet<Version> = required_stops().into_iter().collect();
        assert_eq!(
            listed, from_records,
            "REQUIRED_STOPS must list each release with a `required-stop = true` record"
        );
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
        let refusal = check(&last("0.10.0"), &v("0.12.1"), &stops).unwrap_err();
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
        assert_eq!(check(&last("0.11.0"), &v("0.12.1"), &stops), Ok(()));
    }

    #[test]
    fn a_cluster_without_a_readable_receipt_passes() {
        let stops = [v("0.11.0")];
        assert_eq!(check(&LastWrite::default(), &v("0.12.1"), &stops), Ok(()));
        assert_eq!(
            check(&deployed(None, Some("abc")), &v("0.12.1"), &stops),
            Ok(())
        );
        assert_eq!(check(&last("unknown"), &v("0.12.1"), &stops), Ok(()));
        assert_eq!(check(&last("unknown"), &v("0.8.0"), &stops), Ok(()));
    }

    #[test]
    fn a_deploy_by_an_older_minor_is_refused() {
        let active = deployed(Some("0.9.1"), Some("abc1234def5678"));
        let refusal = check(&active, &v("0.8.4"), &[]).unwrap_err();
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
             is older than Kix 0.9. Nothing was applied. Deploy with Kix 0.9 or newer."
        );
        // A prerelease of the newer minor counts as that minor.
        assert!(older_kix(&last("0.9.0-rc.1"), &v("0.8.4")).is_some());
        assert!(older_kix(&last("1.0.0"), &v("0.12.0")).is_some());
    }

    #[test]
    fn only_the_last_version_named_allows_a_downgrade() {
        let refusal = older_kix(&last("0.9.1+abc"), &v("0.8.4")).unwrap();
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
        assert_eq!(older_kix(&last("0.9.3"), &v("0.9.1")), None);
        assert_eq!(older_kix(&last("0.9.0"), &v("0.9.0-rc.2")), None);
        assert_eq!(older_kix(&last("0.8.4"), &v("0.9.0")), None);
        assert_eq!(older_kix(&LastWrite::default(), &v("0.9.0")), None);
    }

    #[test]
    fn an_unknown_commit_is_left_out() {
        let refusal = older_kix(&last("0.9.1"), &v("0.8.4")).unwrap();
        assert_eq!(refusal.last_deploy(), "Kix 0.9.1");
        let short = older_kix(&deployed(Some("0.9.1"), Some("abc")), &v("0.8.4")).unwrap();
        assert_eq!(short.last_deploy(), "Kix 0.9.1 (from commit abc)");
    }

    /// Once the head names the Kix that wrote last, the checks read it, so
    /// a `kix gc` or a deploy with `--only` by a newer Kix counts too. The
    /// commit of the current record is named only when that record is the
    /// same version's.
    #[test]
    fn the_heads_writer_comes_before_the_record() {
        use crate::cluster::head::Program;
        let rec = record(Some("0.9.1"), Some("abc1234def"));
        let newer = Writer {
            version: "0.11.0".into(),
            program: Program::Cli,
        };
        let last = LastWrite::of(Some(&newer), Some(&rec));
        assert_eq!(last.version.as_deref(), Some("0.11.0"));
        assert_eq!(last.commit, None);
        assert!(older_kix(&last, &v("0.10.2")).is_some());
        let same = Writer {
            version: "0.9.1".into(),
            program: Program::Operator,
        };
        assert_eq!(
            LastWrite::of(Some(&same), Some(&rec)).commit.as_deref(),
            Some("abc1234def")
        );
        assert_eq!(
            LastWrite::of(None, Some(&rec)).version.as_deref(),
            Some("0.9.1")
        );
    }

    #[test]
    fn the_built_in_stops_are_versions() {
        for s in REQUIRED_STOPS {
            assert!(s.parse::<Version>().is_ok(), "{s}");
        }
        assert_eq!(required_stops().len(), REQUIRED_STOPS.len());
    }
}
