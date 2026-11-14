//! The parts of `kix upgrade` that only read the release index and the
//! change records: which release to move to, the steps between, and which
//! records apply to the project.

use std::collections::BTreeSet;

use chrono::NaiveDate;
use kix::changes::{Document, Kind, Record};
use kix::release::index::Release;
use kix::version::Version;
use kix::version::policy::{Requirement, satisfies};

/// Return the releases in the index that have an archive for `system` and
/// are not prereleases, oldest first.
pub fn usable<'a>(releases: &'a [Release], system: &str) -> Vec<&'a Release> {
    let mut out: Vec<&Release> = releases
        .iter()
        .filter(|r| !r.version.is_prerelease() && r.systems.iter().any(|s| s == system))
        .collect();
    out.sort_by(|a, b| a.version.cmp(&b.version));
    out
}

/// Return whether `release` is at least `min_age` days old on `today`. A
/// release without a readable date never counts as old enough.
fn old_enough(release: &Release, min_age: Option<u32>, today: NaiveDate) -> bool {
    let Some(days) = min_age else { return true };
    release
        .date
        .as_deref()
        .and_then(|d| NaiveDate::parse_from_str(d, "%Y-%m-%d").ok())
        .is_some_and(|date| (today - date).num_days() >= i64::from(days))
}

/// Return how many days old the newest of `releases` is on `today`, when
/// its date can be read.
pub fn newest_age(releases: &[&Release], today: NaiveDate) -> Option<i64> {
    let newest = releases.iter().max_by(|a, b| a.version.cmp(&b.version))?;
    let date = NaiveDate::parse_from_str(newest.date.as_deref()?, "%Y-%m-%d").ok()?;
    Some((today - date).num_days())
}

/// Return the release to upgrade to. `to` is the `--to` value as a
/// requirement, or `None` for the newest release. `min_age` skips releases
/// younger than that many days, except a version named exactly.
pub fn choose_target(
    releases: &[&Release],
    to: Option<&Requirement>,
    min_age: Option<u32>,
    today: NaiveDate,
) -> Option<Version> {
    if let Some(Requirement::Exact(v)) = to {
        return releases
            .iter()
            .find(|r| &r.version == v)
            .map(|r| r.version.clone());
    }
    releases
        .iter()
        .filter(|r| to.is_none_or(|req| satisfies(req, &r.version)))
        .filter(|r| old_enough(r, min_age, today))
        .map(|r| r.version.clone())
        .max()
}

/// Return the steps a stepping upgrade from `from` to `to` takes: the newest
/// patch of each minor after `from`'s, up to `to`, which is the last step.
/// When `from` is a prerelease, the newest release of its own minor comes
/// first, since that release is newer than `from`.
pub fn steps(releases: &[&Release], from: &Version, to: &Version) -> Vec<Version> {
    let mut out: Vec<Version> = Vec::new();
    for r in releases {
        let v = &r.version;
        let own_minor = v.minor_key() == from.minor_key() && from.is_prerelease() && v > from;
        if (v.minor_key() <= from.minor_key() && !own_minor) || v.minor_key() >= to.minor_key() {
            continue;
        }
        match out.last_mut() {
            Some(last) if last.minor_key() == v.minor_key() => {
                if v > last {
                    *last = v.clone();
                }
            }
            _ => out.push(v.clone()),
        }
    }
    out.push(to.clone());
    out
}

/// The change records of one release.
#[derive(Debug, Clone)]
pub struct ReleaseRecords {
    pub version: Version,
    /// `None` when the release ships no change records.
    pub document: Option<Document>,
}

/// Return the earliest release after `from` and before `target` with a
/// record that asks clusters to deploy it before upgrading further, and the
/// version the upgrade stops at for it: the newest patch of that release's
/// minor, no newer than `target`. Return `None` when no stop falls before
/// `target`.
pub fn required_stop(
    releases: &[&Release],
    records: &[ReleaseRecords],
    from: &Version,
    target: &Version,
) -> Option<(Version, Version)> {
    let stop = records
        .iter()
        .filter(|r| &r.version > from && &r.version < target)
        .filter(|r| {
            r.document
                .as_ref()
                .is_some_and(|d| d.records.iter().any(|rec| rec.required_stop))
        })
        .map(|r| r.version.clone())
        .min()?;
    let until = releases
        .iter()
        .map(|r| &r.version)
        .filter(|v| v.minor_key() == stop.minor_key() && *v <= target)
        .max()
        .cloned()
        .unwrap_or_else(|| stop.clone());
    (&until < target).then_some((stop, until))
}

/// Return whether `record` names a package whose name is an instance in
/// `in_use`. Records name packages and Kix sees only instance names, so a
/// match is likely, never certain, and no match proves nothing. A record
/// names an experimental package as `experimental/<name>`, and an instance
/// of it is usually called `<name>`.
pub fn likely(record: &Record, in_use: Option<&BTreeSet<String>>) -> bool {
    in_use.is_some_and(|in_use| {
        record
            .packages
            .iter()
            .any(|p| in_use.contains(p.strip_prefix("experimental/").unwrap_or(p)))
    })
}

/// One record in the range of an upgrade, with the release that shipped it.
#[derive(Debug, Clone)]
pub struct Applying {
    pub release: Version,
    pub record: Record,
    /// The record names a package that an instance in use is named after.
    pub likely: bool,
}

impl Applying {
    /// Return the id, or the name for a record without one.
    pub fn reference(&self) -> String {
        self.record
            .id
            .clone()
            .unwrap_or_else(|| self.record.name.clone())
    }
}

/// Return every record of the releases after `from` up to `to`, each
/// marked when it is [`likely`] to touch the project.
pub fn applying(
    records: &[ReleaseRecords],
    from: &Version,
    to: &Version,
    in_use: Option<&BTreeSet<String>>,
) -> Vec<Applying> {
    records
        .iter()
        .filter(|r| &r.version > from && &r.version <= to)
        .flat_map(|r| {
            r.document
                .iter()
                .flat_map(|d| &d.records)
                .map(|rec| Applying {
                    release: r.version.clone(),
                    record: rec.clone(),
                    likely: likely(rec, in_use),
                })
        })
        .collect()
}

/// Return the applying records of `kind`.
pub fn of_kind(applying: &[Applying], kind: Kind) -> Vec<&Applying> {
    applying.iter().filter(|a| a.record.kind == kind).collect()
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;

    fn release(version: &str, date: &str) -> Release {
        Release {
            version: version.parse().unwrap(),
            systems: vec!["x86_64-linux".into()],
            sums: String::new(),
            signature: None,
            download: String::new(),
            date: Some(date.into()),
        }
    }

    fn index() -> Vec<Release> {
        vec![
            release("0.9.0", "2026-09-01"),
            release("0.9.1", "2026-09-10"),
            release("0.10.0", "2026-10-01"),
            release("0.10.1", "2026-10-05"),
            release("0.11.0-rc.1", "2026-10-20"),
            release("0.11.0", "2026-11-01"),
            release("0.11.1", "2026-11-09"),
        ]
    }

    fn v(s: &str) -> Version {
        s.parse().unwrap()
    }

    fn today() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 11, 11).unwrap()
    }

    #[test]
    fn usable_skips_prereleases_and_other_systems() {
        let mut all = index();
        all.push(Release {
            systems: vec!["aarch64-darwin".into()],
            ..release("0.12.0", "2026-11-10")
        });
        let got: Vec<String> = usable(&all, "x86_64-linux")
            .iter()
            .map(|r| r.version.release())
            .collect();
        assert_eq!(
            got,
            ["0.9.0", "0.9.1", "0.10.0", "0.10.1", "0.11.0", "0.11.1"]
        );
    }

    #[test]
    fn the_target_is_the_newest_release_unless_asked_otherwise() {
        let all = index();
        let r = usable(&all, "x86_64-linux");
        assert_eq!(choose_target(&r, None, None, today()), Some(v("0.11.1")));
        assert_eq!(choose_target(&r, None, Some(7), today()), Some(v("0.11.0")));
        assert_eq!(choose_target(&r, None, Some(60), today()), Some(v("0.9.1")));
        assert_eq!(choose_target(&r, None, Some(365), today()), None);
        let minor = Requirement::Minor(0, 10);
        assert_eq!(
            choose_target(&r, Some(&minor), None, today()),
            Some(v("0.10.1"))
        );
        let exact = Requirement::Exact(v("0.10.0"));
        assert_eq!(
            choose_target(&r, Some(&exact), Some(365), today()),
            Some(v("0.10.0"))
        );
        let missing = Requirement::Exact(v("0.10.7"));
        assert_eq!(choose_target(&r, Some(&missing), None, today()), None);
    }

    #[test]
    fn steps_take_the_newest_patch_of_each_minor_between() {
        let all = index();
        let r = usable(&all, "x86_64-linux");
        let s = |from: &str, to: &str| -> Vec<String> {
            steps(&r, &v(from), &v(to))
                .iter()
                .map(Version::release)
                .collect()
        };
        assert_eq!(s("0.9.0", "0.11.1"), ["0.10.1", "0.11.1"]);
        assert_eq!(s("0.9.0", "0.11.0"), ["0.10.1", "0.11.0"]);
        assert_eq!(s("0.9.0", "0.9.1"), ["0.9.1"]);
        assert_eq!(s("0.10.0", "0.11.1"), ["0.11.1"]);
    }

    #[test]
    fn from_0_8_0_rc_1_to_0_9_1() {
        let all = vec![
            release("0.8.0-rc.1", "2026-08-01"),
            release("0.8.0", "2026-08-10"),
            release("0.8.2", "2026-08-20"),
            release("0.9.0", "2026-09-01"),
            release("0.9.1", "2026-09-10"),
        ];
        let r = usable(&all, "x86_64-linux");
        let from = v("0.8.0-rc.1");
        assert!(from < v("0.8.0"));
        let target = choose_target(&r, None, None, today()).unwrap();
        assert_eq!(target, v("0.9.1"));
        assert!(target > from);
        let got: Vec<String> = steps(&r, &from, &target)
            .iter()
            .map(Version::release)
            .collect();
        assert_eq!(got, ["0.8.2", "0.9.1"]);

        // Without a 0.8 release newer than the prerelease, 0.9.1 is the only step.
        let only = vec![
            release("0.8.0-rc.1", "2026-08-01"),
            release("0.9.1", "2026-09-10"),
        ];
        let r = usable(&only, "x86_64-linux");
        let got: Vec<String> = steps(&r, &from, &v("0.9.1"))
            .iter()
            .map(Version::release)
            .collect();
        assert_eq!(got, ["0.9.1"]);
    }

    #[test]
    fn a_prerelease_upgrades_through_its_own_minor() {
        let all = index();
        let r = usable(&all, "x86_64-linux");
        let s = |from: &str, to: &str| -> Vec<String> {
            steps(&r, &v(from), &v(to))
                .iter()
                .map(Version::release)
                .collect()
        };
        assert_eq!(s("0.9.0-rc.1", "0.11.1"), ["0.9.1", "0.10.1", "0.11.1"]);
        assert_eq!(s("0.9.0-rc.1", "0.9.1"), ["0.9.1"]);
        assert_eq!(s("0.11.0-rc.1", "0.11.1"), ["0.11.1"]);
        // A prerelease is older than its release, so the release is newer.
        assert!(v("0.9.0-rc.1") < v("0.9.0"));
        assert_eq!(choose_target(&r, None, None, today()), Some(v("0.11.1")));
        // Every release of its minor counts as after it.
        let records = vec![doc(
            "0.9.0",
            vec![record("r", "+++\nkind = \"added\"\n+++\nNew.\n")],
        )];
        assert_eq!(
            applying(&records, &v("0.9.0-rc.1"), &v("0.9.1"), None).len(),
            1
        );
    }

    pub(in crate::commands::upgrade) fn doc(version: &str, records: Vec<Record>) -> ReleaseRecords {
        ReleaseRecords {
            version: v(version),
            document: Some(Document {
                schema: kix::changes::SCHEMA.into(),
                version: version.into(),
                records,
            }),
        }
    }

    /// Read a record from the file form, a TOML header between `+++` lines
    /// and a body, through the JSON form a release publishes.
    pub(in crate::commands::upgrade) fn record(name: &str, text: &str) -> Record {
        let mut parts = text.splitn(3, "+++\n");
        parts.next();
        let header: toml::Table = toml::from_str(parts.next().unwrap()).unwrap();
        let mut json = serde_json::json!({
            "name": name,
            "touchesData": false,
            "requiredStop": false,
            "body": parts.next().unwrap_or_default(),
        });
        for (key, value) in header {
            let key = match key.as_str() {
                "touches-data" => "touchesData".to_string(),
                "required-stop" => "requiredStop".to_string(),
                other => other.to_string(),
            };
            json[key] = serde_json::to_value(value).unwrap();
        }
        serde_json::from_value(json).unwrap()
    }

    #[test]
    fn a_required_stop_ends_the_upgrade_at_its_minor() {
        let all = index();
        let r = usable(&all, "x86_64-linux");
        let stop = record(
            "move-state",
            "+++\nkind = \"note\"\nstate = true\nrequired-stop = true\n+++\nMoved.\n",
        );
        let records = vec![
            doc("0.10.0", vec![stop]),
            ReleaseRecords {
                version: v("0.10.1"),
                document: None,
            },
        ];
        assert_eq!(
            required_stop(&r, &records, &v("0.9.0"), &v("0.11.1")),
            Some((v("0.10.0"), v("0.10.1")))
        );
        // The stop's own minor is the target, so the upgrade goes there.
        assert_eq!(required_stop(&r, &records, &v("0.9.0"), &v("0.10.1")), None);
        // A stop the project has passed does not count.
        assert_eq!(
            required_stop(&r, &records, &v("0.10.0"), &v("0.11.1")),
            None
        );
    }

    #[test]
    fn every_record_counts_and_matches_are_marked() {
        let general = record("general", "+++\nkind = \"added\"\n+++\nNew.\n");
        let echo = record(
            "echo",
            "+++\nkind = \"error\"\nid = \"K0001\"\npackages = [\"echo-server\"]\n+++\nRenamed.\n",
        );
        let in_use: BTreeSet<String> = ["caddy".to_string(), "echo-server".to_string()].into();
        assert!(likely(&echo, Some(&in_use)));
        assert!(!likely(&general, Some(&in_use)));
        assert!(!likely(&echo, None));
        let experimental = record(
            "experimental",
            "+++\nkind = \"silent\"\npackages = [\"experimental/caddy\"]\n+++\nMoved.\n",
        );
        assert!(likely(&experimental, Some(&in_use)));

        let records = vec![
            doc("0.9.1", vec![general.clone()]),
            doc("0.10.0", vec![echo.clone(), general.clone()]),
            doc("0.11.0", vec![echo]),
        ];
        let got = applying(&records, &v("0.9.1"), &v("0.10.1"), Some(&in_use));
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].reference(), "K0001");
        assert!(got[0].likely);
        assert!(!got[1].likely);
        let all = applying(&records, &v("0.9.0"), &v("0.11.1"), None);
        assert_eq!(all.len(), 4);
        assert!(all.iter().all(|a| !a.likely));
        assert_eq!(of_kind(&all, Kind::Error).len(), 2);
    }
}
