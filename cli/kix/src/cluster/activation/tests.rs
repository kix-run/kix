mod phase_tests {
    use super::super::*;

    #[test]
    fn begin_marks_anything_that_is_not_already_current() {
        for phase in [
            "",
            PHASE_QUEUED,
            PHASE_SUPERSEDED,
            PHASE_FAILED,
            PHASE_DEPLOYING,
        ] {
            assert_eq!(
                phase_on_begin(phase),
                Some(PHASE_DEPLOYING),
                "phase {phase:?} should be marked Deploying",
            );
        }
    }

    #[test]
    fn begin_leaves_the_current_record_alone() {
        // Re-deploying the closure that is already running reuses its record.
        // Demoting it to Deploying and then dying would leave the cluster
        // with no current record at all, and the next deploy would plan as a
        // first deploy: no orphans, no repairs.
        assert_eq!(phase_on_begin(PHASE_ACTIVE), None);
        assert_eq!(phase_on_begin(PHASE_DEGRADED), None);
    }

    #[test]
    fn abort_only_fails_a_record_this_run_marked() {
        assert_eq!(phase_on_abort(PHASE_DEPLOYING), Some(PHASE_FAILED));
        // A record created but never marked can only be ours: `begin` creates
        // it and marks it in two round trips, and a run that dies between the
        // two would otherwise leave it invisible to every reader.
        assert_eq!(phase_on_abort(""), Some(PHASE_FAILED));
        for phase in [
            PHASE_QUEUED,
            PHASE_ACTIVE,
            PHASE_DEGRADED,
            PHASE_SUPERSEDED,
            PHASE_FAILED,
        ] {
            assert_eq!(
                phase_on_abort(phase),
                None,
                "phase {phase:?} is not ours to fail",
            );
        }
    }

    #[test]
    fn a_record_that_never_deployed_sorts_by_when_it_failed() {
        let mut record = Record {
            name: "demo-abc".into(),
            failed_at: Some("2026-09-09T10:00:00Z".into()),
            created_at: parse_time("2026-09-09T09:00:00Z"),
            ..Default::default()
        };
        assert_eq!(
            record.retention_time().map(|t| t.to_rfc3339()),
            Some("2026-09-09T10:00:00+00:00".to_string()),
        );

        // No failure timestamp either: fall back to creation, so it is still
        // not retired as UnknownAge on the first gc.
        record.failed_at = None;
        assert_eq!(
            record.retention_time().map(|t| t.to_rfc3339()),
            Some("2026-09-09T09:00:00+00:00".to_string()),
        );

        record.created_at = None;
        assert_eq!(record.retention_time(), None);
    }

    #[test]
    fn deployed_at_wins_over_the_fallbacks() {
        let record = Record {
            name: "demo-abc".into(),
            deployed_at: Some("2026-09-01T00:00:00Z".into()),
            failed_at: Some("2026-09-09T10:00:00Z".into()),
            created_at: parse_time("2026-09-09T09:00:00Z"),
            ..Default::default()
        };
        assert_eq!(
            record.retention_time().map(|t| t.to_rfc3339()),
            Some("2026-09-01T00:00:00+00:00".to_string()),
        );
    }

    #[test]
    fn the_newest_current_record_wins_and_ties_break_on_name() {
        use chrono::{TimeZone, Utc};
        let at = |h| Some(Utc.with_ymd_and_hms(2026, 9, 9, h, 0, 0).unwrap());

        assert_eq!(
            pick_current(vec![
                ("older", at(9), "b".to_string()),
                ("newer", at(11), "a".to_string()),
            ]),
            Some("newer"),
        );

        // Same timestamp: the name decides, so the plan does not depend on
        // the order the apiserver happened to list them in.
        assert_eq!(
            pick_current(vec![
                ("bee", at(9), "b".to_string()),
                ("ay", at(9), "a".to_string()),
            ]),
            Some("ay"),
        );

        // A record with no usable timestamp sorts oldest rather than winning
        // by accident.
        assert_eq!(
            pick_current(vec![
                ("unstamped", None, "a".to_string()),
                ("stamped", at(9), "z".to_string()),
            ]),
            Some("stamped"),
        );

        assert_eq!(pick_current(Vec::<(&str, _, String)>::new()), None);
    }

    /// Superseded and Failed records stay on the cluster beside the current
    /// one; the current one is chosen by phase, then by deploy time.
    #[test]
    fn current_record_skips_records_that_are_not_current() {
        let record = |name: &str, phase: &str, deployed_at: &str| DynamicObject {
            metadata: kube::api::ObjectMeta {
                name: Some(name.into()),
                annotations: Some(
                    [(keys::DEPLOYED_AT.to_string(), deployed_at.to_string())].into(),
                ),
                ..Default::default()
            },
            types: None,
            data: json!({"status": {"phase": phase}}),
        };
        let records = [
            record("c-new-failed", PHASE_FAILED, "2026-09-09T12:00:00Z"),
            record("c-old", PHASE_SUPERSEDED, "2026-09-09T08:00:00Z"),
            record("c-live", PHASE_ACTIVE, "2026-09-09T10:00:00Z"),
            record("c-older", PHASE_SUPERSEDED, "2026-09-09T09:00:00Z"),
        ];
        let current = current_record(&records).and_then(|r| r.metadata.name.as_deref());
        assert_eq!(current, Some("c-live"));
        assert!(current_record(&records[..2]).is_none());
    }
}

mod orphans_kept_from_tests {
    use std::collections::BTreeMap;

    use super::super::*;

    /// The status list round-trips through JSON and a malformed entry is
    /// dropped without losing the others.
    #[test]
    fn reads_the_list_and_skips_malformed_entries() {
        let written = vec![KeptOrphanSource {
            activation: "c-v1".into(),
            identity_hash: "abc".into(),
            built_via: Some("/nix/store/abc-activation".into()),
        }];
        let obj: DynamicObject = serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": { "name": "c-v2" },
            "status": {
                "phase": PHASE_ACTIVE,
                (keys::ORPHANS_KEPT_FROM_FIELD): [written[0], { "activation": "no-hash" }],
            },
        }))
        .unwrap();
        assert_eq!(Record::of(&obj).orphans_kept_from, written);
        assert_eq!(
            json!(written[0]),
            json!({"activation": "c-v1", "identityHash": "abc", "builtVia": "/nix/store/abc-activation"})
        );
    }

    /// The Kix that made a deploy is read off its receipt: the deployer's
    /// for a bundle, else the builder's, and none without a receipt.
    #[test]
    fn reads_the_kix_that_deployed() {
        let with = |receipt: serde_json::Value| {
            let obj: DynamicObject = serde_json::from_value(json!({
                "apiVersion": keys::API_VERSION,
                "kind": "Activation",
                "metadata": { "name": "c-v1" },
                "status": { (keys::RECEIPT_FIELD): receipt },
            }))
            .unwrap();
            Record::of(&obj).deployed_with
        };
        assert_eq!(
            with(json!({"builder": {"kixVersion": "0.10.0"}})).as_deref(),
            Some("0.10.0")
        );
        assert_eq!(
            with(json!({"builder": {"kixVersion": "0.9.0"}, "deployer": {"kixVersion": "0.10.1"}}))
                .as_deref(),
            Some("0.10.1")
        );
        assert_eq!(with(json!(null)), None);
    }

    /// A consumer's pinned interfaces and a platform's published hashes are
    /// read off `spec`; a malformed entry is left out.
    #[test]
    fn reads_interfaces_and_published_hashes() {
        let obj: DynamicObject = serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": { "name": "c-v1" },
            "spec": {
                "interfaces": {
                    "prod": { "consumer": "acme", "path": "kix-interface/prod.json", "sha256": "aa" },
                    "broken": { "consumer": "acme" },
                },
                "consumers": {
                    "acme": { "interface": "/nix/store/x-kix-interface-acme.json", "sha256": "bb" },
                    "old": { "interface": "/nix/store/y-kix-interface-old.json" },
                },
            },
        }))
        .unwrap();
        let record = Record::of(&obj);
        assert_eq!(
            record.interfaces,
            BTreeMap::from([(
                "prod".to_string(),
                PinnedInterface {
                    consumer: "acme".into(),
                    path: "kix-interface/prod.json".into(),
                    sha256: "aa".into(),
                }
            )])
        );
        assert_eq!(
            record.published_interfaces,
            BTreeMap::from([("acme".to_string(), "bb".to_string())])
        );
    }

    fn source(name: &str) -> KeptOrphanSource {
        KeptOrphanSource {
            activation: name.into(),
            identity_hash: format!("{name}-hash"),
            built_via: None,
        }
    }

    fn names(sources: &[KeptOrphanSource]) -> Vec<&str> {
        sources.iter().map(|s| s.activation.as_str()).collect()
    }

    /// Found sources are written only while an orphan is left; unexamined
    /// ones are written either way, so a `--prune` run on a machine that
    /// cannot read a listed build does not forget it.
    #[test]
    fn unexamined_sources_survive_a_run_that_left_no_orphans() {
        let kept = KeptOrphans {
            found: vec![source("v1")],
            unexamined: vec![source("elsewhere")],
            carry_current: false,
        };
        assert_eq!(names(&kept.recorded(None, true)), vec!["v1", "elsewhere"]);
        assert_eq!(names(&kept.recorded(None, false)), vec!["elsewhere"]);
        assert!(KeptOrphans::default().recorded(None, true).is_empty());
    }

    /// The current record's list is carried only when asked for, deduplicated
    /// against what the plan found.
    #[test]
    fn the_current_list_is_carried_when_the_plan_did_not_read_it() {
        let current = [source("v1"), source("v0")];
        let mut kept = KeptOrphans {
            found: vec![source("v1")],
            unexamined: vec![],
            carry_current: false,
        };
        assert_eq!(names(&kept.recorded(Some(&current), true)), vec!["v1"]);
        kept.carry_current = true;
        assert_eq!(
            names(&kept.recorded(Some(&current), true)),
            vec!["v1", "v0"]
        );
        assert_eq!(
            names(&kept.recorded(Some(&current), false)),
            vec!["v1", "v0"]
        );
        assert!(kept.recorded(None, false).is_empty());
    }
}

mod retire_plan_tests {
    use super::super::*;
    use chrono::{Duration, TimeZone, Utc};

    fn now() -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 7, 12, 0, 0).unwrap()
    }

    fn rec(name: &str, deployed_at: &str) -> Record {
        Record {
            name: name.into(),
            deployed_at: Some(deployed_at.into()),
            ..Default::default()
        }
    }

    /// Construct a record deployed `days` days before `now()`.
    fn aged(name: &str, days: i64) -> Record {
        rec(name, &(now() - Duration::days(days)).to_rfc3339())
    }

    fn names(v: &[Record]) -> Vec<&str> {
        v.iter().map(|r| r.name.as_str()).collect()
    }

    fn retired(v: &[Retired]) -> Vec<(&str, RetireReason)> {
        v.iter()
            .map(|r| (r.record.name.as_str(), r.reason.clone()))
            .collect()
    }

    fn older_than_30d() -> RetireReason {
        RetireReason::OlderThan(Duration::days(30))
    }

    fn policy(keep_min: usize, keep_max: usize, keep_for_days: Option<i64>) -> RetentionPolicy {
        RetentionPolicy {
            keep_min,
            keep_max,
            keep_for: keep_for_days.map(Duration::days),
            now: now(),
        }
    }

    #[test]
    fn defaults_keep_ten_and_cap_fifty() {
        assert_eq!((DEFAULT_KEEP_MIN, DEFAULT_KEEP_MAX), (10, 50));
    }

    #[test]
    fn the_floor_keeps_the_newest_whatever_their_age() {
        // Twelve records, one per year: all far older than 30 days.
        let input: Vec<_> = (0..12)
            .map(|i| aged(&format!("c-{i:02}"), 365 * (i + 1)))
            .collect();
        let plan = retire_plan(input, &policy(10, 50, Some(30)));
        assert_eq!(plan.kept.len(), 10);
        assert_eq!(plan.kept[0].name, "c-00", "newest first");
        assert_eq!(
            retired(&plan.retire),
            vec![("c-10", older_than_30d()), ("c-11", older_than_30d())]
        );
    }

    #[test]
    fn the_cap_retires_even_recent_records() {
        // Sixty records deployed in the last hour.
        let input: Vec<_> = (0..60)
            .map(|i| {
                rec(
                    &format!("c-{i:02}"),
                    &(now() - Duration::minutes(i)).to_rfc3339(),
                )
            })
            .collect();
        let plan = retire_plan(input, &policy(10, 50, Some(30)));
        assert_eq!(plan.kept.len(), 50);
        assert_eq!(plan.retire.len(), 10);
        assert!(
            plan.retire
                .iter()
                .all(|r| r.reason == RetireReason::BeyondMax(50))
        );
        assert_eq!(plan.retire[0].record.name, "c-50");
    }

    #[test]
    fn the_age_rule_applies_only_between_floor_and_cap() {
        let input = vec![
            aged("new-a", 1),
            aged("new-b", 2),
            aged("old-c", 40),
            aged("old-d", 400),
        ];
        // Floor 1: new-a kept by floor; new-b kept by age; old-c and old-d
        // retired by age.
        let plan = retire_plan(input.clone(), &policy(1, 50, Some(30)));
        assert_eq!(names(&plan.kept), vec!["new-a", "new-b"]);
        assert_eq!(
            retired(&plan.retire),
            vec![("old-c", older_than_30d()), ("old-d", older_than_30d())]
        );
        // Floor 3: old-c now protected by the floor.
        let plan = retire_plan(input, &policy(3, 50, Some(30)));
        assert_eq!(names(&plan.kept), vec!["new-a", "new-b", "old-c"]);
        assert_eq!(retired(&plan.retire), vec![("old-d", older_than_30d())]);
    }

    #[test]
    fn age_rule_off_keeps_everything_up_to_the_cap() {
        let input: Vec<_> = (0..5)
            .map(|i| aged(&format!("c-{i}"), 1000 * (i + 1)))
            .collect();
        let plan = retire_plan(input, &policy(1, 3, None));
        assert_eq!(names(&plan.kept), vec!["c-0", "c-1", "c-2"]);
        assert_eq!(
            retired(&plan.retire),
            vec![
                ("c-3", RetireReason::BeyondMax(3)),
                ("c-4", RetireReason::BeyondMax(3))
            ]
        );
    }

    /// Construct a record superseded out of `Failed` `days` days before `now()`.
    fn failed(name: &str, days: i64) -> Record {
        Record {
            name: name.into(),
            failed_at: Some((now() - Duration::days(days)).to_rfc3339()),
            ..Default::default()
        }
    }

    /// A good deploy 40 days old, then ten failed deploys. The failed ones
    /// take no place in the floor, so the good one, the only rollback
    /// target, is kept; the failed ones are recent and kept by age.
    #[test]
    fn failed_deploys_do_not_push_the_last_rollback_target_out() {
        let mut input = vec![aged("good", 40)];
        input.extend((1..=10).map(|i| failed(&format!("f{i:02}"), i)));
        let plan = retire_plan(input, &policy(DEFAULT_KEEP_MIN, DEFAULT_KEEP_MAX, Some(30)));
        assert!(plan.retire.is_empty(), "{:?}", retired(&plan.retire));
        assert!(names(&plan.kept).contains(&"good"));

        // Past the age rule a failed record is retired, whatever the floor.
        let plan = retire_plan(
            vec![aged("good", 40), failed("old-failure", 35)],
            &policy(DEFAULT_KEEP_MIN, DEFAULT_KEEP_MAX, Some(30)),
        );
        assert_eq!(names(&plan.kept), vec!["good"]);
        assert_eq!(
            retired(&plan.retire),
            vec![("old-failure", older_than_30d())]
        );
    }

    /// With the age rule off, sixty failed deploys are still capped.
    #[test]
    fn the_cap_holds_for_records_that_never_finished() {
        let input: Vec<_> = (1..=60).map(|i| failed(&format!("f{i:02}"), i)).collect();
        let plan = retire_plan(input, &policy(10, 50, None));
        assert_eq!(plan.kept.len(), 50);
        assert_eq!(plan.retire.len(), 10);
        assert!(
            plan.retire
                .iter()
                .all(|r| r.reason == RetireReason::BeyondMax(50))
        );
        assert_eq!(plan.retire[0].record.name, "f51", "newest first");
    }

    /// Over the cap with both kinds, the failed records go, oldest first,
    /// and no rollback target within the floor is retired.
    #[test]
    fn over_the_cap_the_oldest_failed_records_go_first() {
        let mut input: Vec<_> = (1..=3).map(|i| aged(&format!("good{i}"), i * 10)).collect();
        input.extend((1..=4).map(|i| failed(&format!("f{i}"), i)));
        let plan = retire_plan(input, &policy(2, 4, None));
        assert_eq!(names(&plan.kept), vec!["f1", "good1", "good2", "good3"]);
        let gone: Vec<&str> = plan.retire.iter().map(|r| r.record.name.as_str()).collect();
        assert_eq!(gone, vec!["f2", "f3", "f4"]);
    }

    #[test]
    fn unknown_age_sorts_oldest_and_is_retired_by_the_age_rule_only() {
        let input = vec![
            rec("untimed", ""),
            aged("new", 1),
            rec("garbage-time", "yesterday"),
        ];
        let plan = retire_plan(input.clone(), &policy(1, 50, Some(30)));
        assert_eq!(names(&plan.kept), vec!["new"]);
        assert_eq!(
            retired(&plan.retire),
            vec![
                ("garbage-time", RetireReason::UnknownAge),
                ("untimed", RetireReason::UnknownAge)
            ]
        );
        // With the age rule off they are kept like anything else.
        let plan = retire_plan(input, &policy(1, 50, None));
        assert_eq!(plan.kept.len(), 3);
    }

    #[test]
    fn exactly_the_floor_retires_nothing_and_zero_floor_with_zero_cap_retires_all() {
        let input: Vec<_> = (0..3).map(|i| aged(&format!("c-{i}"), i + 1)).collect();
        let plan = retire_plan(input.clone(), &policy(3, 50, Some(30)));
        assert!(plan.retire.is_empty());
        let plan = retire_plan(input, &policy(0, 0, None));
        assert!(plan.kept.is_empty());
        assert_eq!(plan.retire.len(), 3);
    }

    #[test]
    fn cap_below_floor_is_raised_to_the_floor() {
        let input: Vec<_> = (0..5).map(|i| aged(&format!("c-{i}"), i + 1)).collect();
        let plan = retire_plan(input, &policy(4, 2, None));
        assert_eq!(plan.kept.len(), 4);
        assert_eq!(plan.retire.len(), 1);
    }

    #[test]
    fn order_is_by_parsed_time_not_by_string_or_name() {
        // Different offsets and precision for the timestamps, and names
        // that run the other way round.
        let input = || {
            vec![
                rec("z-oldest", "2026-01-01T00:00:00+00:00"),
                rec("m-middle", "2026-05-01T02:00:00+02:00"),
                rec("a-newest", "2026-09-01T00:00:00.123456+00:00"),
            ]
        };
        // Age rule off, cap not reached: everything kept, newest first.
        let plan = retire_plan(input(), &policy(1, 50, None));
        assert_eq!(names(&plan.kept), vec!["a-newest", "m-middle", "z-oldest"]);
        assert!(plan.retire.is_empty());
        // Cap of one: the two older ones go, oldest last.
        let plan = retire_plan(input(), &policy(1, 1, None));
        assert_eq!(names(&plan.kept), vec!["a-newest"]);
        let rest: Vec<&str> = plan.retire.iter().map(|r| r.record.name.as_str()).collect();
        assert_eq!(rest, vec!["m-middle", "z-oldest"]);
    }

    #[test]
    fn ties_break_on_name() {
        let same = "2026-09-01T00:00:00Z";
        let input = vec![rec("b", same), rec("c", same), rec("a", same)];
        let plan = retire_plan(input, &policy(2, 2, None));
        assert_eq!(names(&plan.kept), vec!["a", "b"]);
        assert_eq!(plan.retire[0].record.name, "c");
    }
}

mod retire_plan_properties {
    use super::super::*;
    use chrono::{Duration, TimeZone, Utc};
    use proptest::prelude::*;

    /// Construct a test record by kind (`0` for a finished deploy, `1` for a
    /// failed deploy, and `2` for a record with only a creation timestamp) and
    /// age in hours before `now()`.
    fn record(i: usize, kind: u8, hours: i64) -> Record {
        let now = Utc.with_ymd_and_hms(2026, 9, 7, 12, 0, 0).unwrap();
        let at = now - Duration::hours(hours);
        let mut record = Record {
            name: format!("r{i:03}"),
            ..Default::default()
        };
        match kind {
            0 => record.deployed_at = Some(at.to_rfc3339()),
            1 => record.failed_at = Some(at.to_rfc3339()),
            _ => record.created_at = Some(at),
        }
        record
    }

    proptest! {
        /// Whatever the mix: every record is kept or retired, once; no more
        /// than the cap is kept; and the floor's newest rollback targets
        /// are kept.
        #[test]
        fn retention_keeps_the_floor_and_the_cap(
            records in prop::collection::vec((0u8..3, 0i64..3000), 0..90),
            keep_min in 0usize..15,
            keep_max in 0usize..60,
            keep_for_days in prop::option::of(0i64..60),
        ) {
            let input: Vec<Record> = records
                .iter()
                .enumerate()
                .map(|(i, (kind, hours))| record(i, *kind, *hours))
                .collect();
            let policy = RetentionPolicy {
                keep_min,
                keep_max,
                keep_for: keep_for_days.map(Duration::days),
                now: Utc.with_ymd_and_hms(2026, 9, 7, 12, 0, 0).unwrap(),
            };
            let plan = retire_plan(input.clone(), &policy);

            let mut seen: Vec<&str> = plan
                .kept
                .iter()
                .map(|r| r.name.as_str())
                .chain(plan.retire.iter().map(|r| r.record.name.as_str()))
                .collect();
            seen.sort();
            let mut all: Vec<&str> = input.iter().map(|r| r.name.as_str()).collect();
            all.sort();
            prop_assert_eq!(seen, all);

            prop_assert!(plan.kept.len() <= keep_min.max(keep_max));

            let mut targets: Vec<Record> =
                input.into_iter().filter(Record::was_ever_current).collect();
            sort_newest_first(&mut targets);
            for floor in targets.iter().take(keep_min) {
                prop_assert!(plan.kept.contains(floor), "{} retired", floor.name);
            }
        }
    }
}

mod listing_tests {
    use super::super::*;

    /// Records are found by their cluster label, in any phase, and a cluster
    /// label nothing carries finds none.
    #[tokio::test]
    async fn records_exist_finds_records_by_their_cluster_label() {
        let api = crate::cluster::fake_api::FakeApi::new([serde_json::json!({
            "apiVersion": keys::API_VERSION,
            "kind": crate::manifest::lifecycle::RECORD_KIND,
            "metadata": {
                "name": "rec-a1",
                "labels": {
                    "app.kubernetes.io/managed-by": "kix",
                    (keys::CLUSTER_LABEL): "test-harbor",
                },
            },
            "status": { "phase": PHASE_SUPERSEDED },
        })]);
        let client = api.client();
        assert!(records_exist(&client, "test-harbor").await.unwrap());
        assert!(!records_exist(&client, "harbor").await.unwrap());
    }

    /// A record superseded out of `Failed` still carries its failure. It is
    /// listed, so `kix gc` can retire it by when it failed, and it is not a
    /// rollback target. A record that finished a deploy and then carries a
    /// failure, as an interrupted rollback to it leaves, is listed and is a
    /// rollback target.
    #[tokio::test]
    async fn a_record_superseded_out_of_failed_is_listed_for_retention() {
        let record = |name: &str, status: serde_json::Value, deployed_at: Option<&str>| {
            let mut annotations = serde_json::Map::new();
            if let Some(at) = deployed_at {
                annotations.insert(keys::DEPLOYED_AT.into(), json!(at));
            }
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": crate::manifest::lifecycle::RECORD_KIND,
                "metadata": {
                    "name": name,
                    "labels": {
                        "app.kubernetes.io/managed-by": "kix",
                        (keys::CLUSTER_LABEL): "c",
                    },
                    "annotations": annotations,
                },
                "status": status,
            })
        };
        let api = crate::cluster::fake_api::FakeApi::new([
            record(
                "c-ran",
                json!({ "phase": PHASE_SUPERSEDED }),
                Some("2026-09-01T00:00:00Z"),
            ),
            record(
                "c-failed",
                json!({
                    "phase": PHASE_SUPERSEDED,
                    "failure": { "reason": "cancelled", "at": "2026-08-01T00:00:00Z" },
                }),
                None,
            ),
            record(
                "c-interrupted",
                json!({
                    "phase": PHASE_SUPERSEDED,
                    "failure": { "reason": "cancelled", "at": "2026-09-20T00:00:00Z" },
                }),
                Some("2026-09-15T00:00:00Z"),
            ),
        ]);
        let client = api.client();
        let discovery = crate::cluster::discovery::discover_resources(&client)
            .await
            .unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let listed = records.superseded("c").await.unwrap();
        let names: Vec<&str> = listed.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, vec!["c-interrupted", "c-ran", "c-failed"]);

        // Past the floor and older than the age rule, it is retired by when
        // it failed, not kept forever.
        let now = chrono::DateTime::parse_from_rfc3339("2026-10-01T00:00:00Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        let policy = RetentionPolicy {
            keep_min: 1,
            keep_max: 50,
            keep_for: Some(chrono::Duration::days(30)),
            now,
        };
        let plan = retire_plan(listed, &policy);
        assert_eq!(plan.retire.len(), 1);
        assert_eq!(plan.retire[0].record.name, "c-failed");
        assert_eq!(
            plan.retire[0].reason,
            RetireReason::OlderThan(chrono::Duration::days(30))
        );
        let targets = records.rollback_targets("c").await.unwrap();
        let names: Vec<&str> = targets.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, vec!["c-interrupted", "c-ran"]);
    }

    /// A record constructed in memory without server metadata has an empty
    /// `uid` and `resourceVersion`, which `retire` still sends as
    /// preconditions so the live record of that name on the cluster is not
    /// deleted.
    #[tokio::test]
    async fn a_record_not_read_from_the_cluster_is_not_retired() {
        let api = crate::cluster::fake_api::FakeApi::new([json!({
            "apiVersion": keys::API_VERSION,
            "kind": crate::manifest::lifecycle::RECORD_KIND,
            "metadata": { "name": "c-made-up" },
            "status": { "phase": PHASE_SUPERSEDED },
        })]);
        let client = api.client();
        let discovery = crate::cluster::discovery::discover_resources(&client)
            .await
            .unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let made_up = Record {
            name: "c-made-up".into(),
            ..Default::default()
        };
        let err = records.retire(&made_up).await.unwrap_err();
        assert!(
            crate::cluster::errors::classify(&err.source)
                == crate::cluster::errors::FailureClass::Conflict,
            "{err}"
        );
        assert_eq!(
            api.names(crate::manifest::lifecycle::RECORD_KIND),
            vec!["c-made-up"]
        );
    }

    /// A record that changed after it was read is not deleted, and the
    /// error says which operation on which record failed.
    #[tokio::test]
    async fn a_failed_retire_names_the_delete_and_the_record() {
        let api = crate::cluster::fake_api::FakeApi::new([json!({
            "apiVersion": keys::API_VERSION,
            "kind": crate::manifest::lifecycle::RECORD_KIND,
            "metadata": { "name": "c-old" },
            "status": { "phase": PHASE_SUPERSEDED },
        })]);
        let client = api.client();
        let discovery = crate::cluster::discovery::discover_resources(&client)
            .await
            .unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let read = records.get("c-old").await.unwrap().unwrap();
        api.after_get("c-old", |o| o["status"]["phase"] = json!(PHASE_ACTIVE));
        records.get("c-old").await.unwrap();
        let err = records.retire(&read).await.unwrap_err().to_string();
        assert!(
            err.starts_with("failed to delete activation 'c-old': "),
            "{err}"
        );
        assert_eq!(
            api.names(crate::manifest::lifecycle::RECORD_KIND),
            vec!["c-old"]
        );
    }

    fn discovery_with(groups: &[&str]) -> Vec<(ApiResource, Scope)> {
        groups
            .iter()
            .map(|group| {
                let gvk = kube::api::GroupVersionKind::gvk(
                    group,
                    "v1alpha1",
                    crate::manifest::lifecycle::RECORD_KIND,
                );
                (
                    ApiResource::from_gvk_with_plural(&gvk, "activations"),
                    Scope::Cluster,
                )
            })
            .collect()
    }

    /// Records open only past the gate: a cluster whose records sit under a
    /// retired group, alone or beside the current one, is refused. Without
    /// the kind there are no records, which is not an error until a command
    /// needs them.
    #[tokio::test]
    async fn records_open_only_past_the_domain_gate() {
        let client = crate::cluster::fake_api::FakeApi::new([]).client();
        let retired = crate::legacy_domain::DOMAINS[0];

        let opened = Records::open(&client, &discovery_with(&[keys::GROUP])).unwrap();
        assert_eq!(
            opened.records().unwrap().watch_resource().group,
            keys::GROUP
        );

        assert!(matches!(
            Records::open(&client, &discovery_with(&[retired])),
            Err(LegacyDomainError::NotMigrated { .. })
        ));
        assert!(matches!(
            Records::open(&client, &discovery_with(&[retired, keys::GROUP])),
            Err(LegacyDomainError::BothGroups { .. })
        ));

        assert!(Records::open(&client, &[]).unwrap().records().is_none());
        assert!(matches!(
            Records::open_installed(&client, &[]),
            Err(OpenError::NotInstalled)
        ));
        assert!(matches!(
            Records::open_installed(&client, &discovery_with(&[retired])),
            Err(OpenError::Domain(_))
        ));
    }
}

mod package_index_tests {
    use super::super::*;
    use crate::cluster::fake_api::FakeApi;
    use crate::eval::package_index::{FORMAT, IndexedPackage};
    use std::collections::BTreeMap;

    fn index(resources: usize) -> RecordPackageIndex {
        let hash = |i: usize| format!("{i:0>32}");
        RecordPackageIndex {
            format: FORMAT,
            packages: BTreeMap::from([(
                "app/web".to_string(),
                IndexedPackage {
                    instance: hash(0),
                    resources: (1..=resources).map(hash).collect(),
                },
            )]),
            cluster_level: vec![hash(resources + 1)],
        }
    }

    async fn records_with(api: &FakeApi) -> Records {
        let client = api.client();
        let discovery = crate::cluster::discovery::discover_resources(&client)
            .await
            .unwrap();
        Records::open_installed(&client, &discovery).unwrap()
    }

    fn record(name: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": crate::manifest::lifecycle::RECORD_KIND,
            "metadata": { "name": name },
        })
    }

    /// `begin_deploy` writes the build's package index, with its format
    /// number, beside the wave counters, and the record reads it back.
    #[tokio::test]
    async fn begin_deploy_writes_the_package_index() {
        let api = FakeApi::new([record("c-new")]);
        let records = records_with(&api).await;
        records
            .begin_deploy("c-new", 1, Some(&index(2)))
            .await
            .unwrap();
        let read = records.get("c-new").await.unwrap().unwrap();
        assert_eq!(read.phase, PHASE_DEPLOYING);
        assert_eq!(read.package_index, Some(index(2)));

        let obj = records.api().get("c-new").await.unwrap();
        let stored = &obj.data["status"][keys::PACKAGE_INDEX_FIELD];
        assert_eq!(stored["format"], json!(FORMAT));
        assert_eq!(
            stored["packages"]["app/web"]["resources"],
            json!([format!("{:0>32}", 1), format!("{:0>32}", 2)])
        );
        assert_eq!(stored["clusterLevel"], json!([format!("{:0>32}", 3)]));
    }

    /// An index over the size limit is not written, and the deploy still
    /// begins. A record without an index reads as having none.
    #[tokio::test]
    async fn an_oversized_index_is_skipped_and_the_deploy_begins() {
        let api = FakeApi::new([record("c-big")]);
        let records = records_with(&api).await;
        let big = index(crate::eval::package_index::MAX_BYTES / 32);
        records.begin_deploy("c-big", 1, Some(&big)).await.unwrap();
        let read = records.get("c-big").await.unwrap().unwrap();
        assert_eq!(read.phase, PHASE_DEPLOYING);
        assert_eq!(read.package_index, None);
    }
}
