use std::collections::HashSet;

use kix::cluster::activation::{Record, RetentionPolicy, RetireReason, retire_plan};
use kix::manifest::types::CLUSTER_SCOPED;

use super::*;

mod kept_garbage_tests {
    use super::*;
    use serde_json::json;

    fn m(kind: &str, name: &str, hash: &str) -> Value {
        json!({
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": "d",
                "annotations": { keys::IDENTITY_HASH: hash },
            },
        })
    }

    /// Verify that `kept_garbage` returns manifests present only in a kept
    /// closure once each.
    #[test]
    fn objects_only_a_kept_closure_has_are_garbage_once() {
        let kept = vec![
            vec![
                m("Deployment", "web", "h0"),
                m("ConfigMap", "old", "h1"),
                json!({"apiVersion": keys::API_VERSION, "kind": lifecycle::RECORD_KIND, "metadata": {"name": "c-v1", "annotations": { keys::IDENTITY_HASH: "h2" }}}),
            ],
            vec![m("ConfigMap", "old", "h1"), m("Secret", "listed", "h3")],
        ];
        let active_ids: HashSet<String> = [
            "Deployment/d/web".to_string(),
            "Secret/d/listed".to_string(),
        ]
        .into();

        let got: Vec<String> = kept_garbage(&kept, &active_ids)
            .iter()
            .map(k8s_identity)
            .collect();
        assert_eq!(got, vec!["ConfigMap/d/old"]);
    }

    /// Verify that after a rollback gc deletes what the build rolled back
    /// from left behind, and keeps the workload of the restored build.
    ///
    /// `web` was renamed to `web2` and deployed (build B), then the cluster
    /// rolled back to build A without `--prune`. A is Active and lists B under
    /// `orphansKeptFrom`; the files still make B.
    #[test]
    fn after_a_rollback_gc_deletes_the_newer_build_s_leftovers() {
        let build_a = [
            m("Deployment", "web", "a-web"),
            m("Service", "web", "a-svc"),
        ];
        let build_b = [
            m("Deployment", "web2", "b-web2"),
            m("Service", "web2", "b-svc"),
        ];
        let kept = [build_b.to_vec()];
        let ids = |b: &[Value]| -> HashSet<String> { b.iter().map(k8s_identity).collect() };

        let got: Vec<String> = kept_garbage(&kept, &ids(&build_a))
            .iter()
            .map(k8s_identity)
            .collect();
        assert_eq!(got, vec!["Deployment/d/web2", "Service/d/web2"]);

        // The same kept build compared with the build from the files (B)
        // finds nothing, and the files build is refused below, so `web` is
        // never planned for deletion.
        assert!(kept_garbage(&kept, &ids(&build_b)).is_empty());
    }

    /// Verify that a full scan's reason names the build this run compared
    /// with, never a choice of two.
    #[test]
    fn the_reason_names_the_build_compared_with() {
        let label = GarbageReason::NotInBuild.label("the build of active deployment c-v2");
        assert_eq!(label, "not in the build of active deployment c-v2");
    }

    /// Verify that gc uses the build from the current files only when it is
    /// the build the Active record names.
    #[test]
    fn a_files_build_other_than_the_active_build_is_refused() {
        let active = Record {
            name: "c-a".into(),
            identity_hash: Some("aaaaaaaa1111".into()),
            ..Default::default()
        };
        assert!(check_files_build("c", &active, Some("aaaaaaaa1111"), &[]).is_ok());

        let err = check_files_build("c", &active, Some("bbbbbbbb2222"), &[])
            .unwrap_err()
            .to_string();
        assert!(err.contains("Nothing was deleted"), "{err}");
        assert!(err.contains("c-a (build aaaaaaaa)"), "{err}");
        assert!(err.contains("build bbbbbbbb"), "{err}");
        assert!(!err.contains("--only"), "{err}");
        assert!(check_files_build("c", &active, None, &[]).is_err());

        let unhashed = Record {
            identity_hash: None,
            ..active
        };
        assert!(check_files_build("c", &unhashed, None, &[]).is_err());
    }

    /// When a deploy with `--only` left the files' build partly deployed,
    /// the refusal names that record and what it applied.
    #[test]
    fn the_refusal_names_a_partial_deploy_of_the_files_build() {
        let active = Record {
            name: "c-a".into(),
            identity_hash: Some("aaaaaaaa1111".into()),
            ..Default::default()
        };
        let partial: Record = Record::of(
            &serde_json::from_value(serde_json::json!({
                "apiVersion": kix::manifest::keys::API_VERSION,
                "kind": "Activation",
                "metadata": {
                    "name": "c-b",
                    "annotations": { (kix::manifest::keys::IDENTITY_HASH): "bbbbbbbb2222" },
                },
                "status": {
                    "phase": "Partial",
                    "partial": { "only": ["app/api", "web/shop"], "at": "2026-11-25T10:00:00Z" },
                },
            }))
            .unwrap(),
        );
        let err = check_files_build(
            "c",
            &active,
            Some("bbbbbbbb2222"),
            std::slice::from_ref(&partial),
        )
        .unwrap_err()
        .to_string();
        assert!(
            err.contains("Deployment record c-b already deployed part of your local build (`kix deploy --only` applied app/api, web/shop). Run `kix deploy c` to finish deploying it, then run `kix gc c` again."),
            "{err}"
        );
        let err = check_files_build("c", &active, Some("cccccccc3333"), &[partial])
            .unwrap_err()
            .to_string();
        assert!(!err.contains("c-b"), "{err}");
    }

    /// Verify that `may_clear_kept` permits clearing only when the build hash
    /// matches the Active record and all resources were examined.
    #[test]
    fn kept_list_is_cleared_only_after_a_complete_gc_of_the_active_build() {
        use kix::cluster::activation::KeptOrphanSource;
        let active = |kept: bool| {
            let mut record = Record {
                name: "c-v2".into(),
                identity_hash: Some("h-v2".into()),
                ..Default::default()
            };
            if kept {
                record.orphans_kept_from = vec![KeptOrphanSource {
                    activation: "c-v1".into(),
                    identity_hash: "h-v1".into(),
                    built_via: None,
                }];
            }
            record
        };
        assert!(may_clear_kept(&active(true), true, Some("h-v2")));
        let nothing_listed = KeptUpdate::Builds {
            listed: false,
            examined_all: true,
            build_hash: Some("h-v2".into()),
        };
        assert!(!nothing_listed.writes_without_deletes(&active(false)));
        assert!(!may_clear_kept(&active(true), false, Some("h-v2")));
        assert!(!may_clear_kept(&active(true), true, Some("h-v3")));
        assert!(!may_clear_kept(&active(true), true, None));
        let mut unhashed = active(true);
        unhashed.identity_hash = None;
        assert!(!may_clear_kept(&unhashed, true, None));
    }
}

mod record_garbage_tests {
    use super::*;

    fn rec(name: &str, at: &str) -> Record {
        Record {
            name: name.into(),
            identity_hash: Some(format!("{name}hash")),
            deployed_at: Some(at.into()),
            ..Default::default()
        }
    }

    /// Verify that `record_garbage` emits cluster-scoped `Activation` entries
    /// only for retired records and never for kept records.
    #[test]
    fn hard_mode_garbage_is_exactly_the_retired_records() {
        let policy = RetentionPolicy {
            keep_min: 1,
            keep_max: 1,
            keep_for: None,
            now: chrono::Utc::now(),
        };
        let plan = retire_plan(
            vec![
                rec("c-1", "2026-09-01T00:00:00Z"),
                rec("c-2", "2026-09-02T00:00:00Z"),
                rec("c-3", "2026-09-03T00:00:00Z"),
            ],
            &policy,
        );
        let entries = record_garbage(&plan);
        let names: Vec<&str> = entries.iter().map(|e| e.id.name.as_str()).collect();
        assert_eq!(names, vec!["c-2", "c-1"]);
        assert!(entries.iter().all(|e| {
            e.reason == GarbageReason::RetiredActivation
                && e.id.kind == lifecycle::RECORD_KIND
                && e.id.namespace == CLUSTER_SCOPED
        }));
        assert!(!names.contains(&"c-3"), "the kept record is never garbage");
        assert_eq!(entries[0].identity_hash.as_deref(), Some("c-2hash"));
    }

    #[test]
    fn retention_durations_parse() {
        let d = |s: &str| parse_retention_duration(s).unwrap();
        assert_eq!(d("30d"), Some(chrono::Duration::days(30)));
        assert_eq!(d("30"), Some(chrono::Duration::days(30)));
        assert_eq!(d("12h"), Some(chrono::Duration::hours(12)));
        assert_eq!(d("45m"), Some(chrono::Duration::minutes(45)));
        assert_eq!(d("10s"), Some(chrono::Duration::seconds(10)));
        assert_eq!(d("0"), None);
        assert_eq!(d("off"), None);
        assert!(parse_retention_duration("3w").is_err());
        assert!(parse_retention_duration("soon").is_err());
    }

    #[test]
    fn humanize_picks_the_largest_even_unit() {
        use chrono::Duration;
        assert_eq!(humanize(Duration::days(30)), "30d");
        assert_eq!(humanize(Duration::hours(36)), "36h");
        assert_eq!(humanize(Duration::minutes(90)), "90m");
        assert_eq!(humanize(Duration::seconds(45)), "45s");
    }

    #[test]
    fn retire_reasons_in_words() {
        let reason = |r: RetireReason| describe_reason(&r);
        assert_eq!(
            reason(RetireReason::OlderThan(chrono::Duration::days(30))),
            "older than 30d"
        );
        assert_eq!(reason(RetireReason::BeyondMax(3)), "beyond the 3 newest");
        assert_eq!(reason(RetireReason::UnknownAge), "age unknown");
    }

    /// Verify that `judged_by` formats the timestamp used by retention for both
    /// deployed and failed records.
    #[test]
    fn a_retired_record_is_shown_by_the_time_it_was_judged_by() {
        assert_eq!(
            judged_by(&rec("c-1", "2026-09-01T00:00:00Z")),
            "2026-09-01T00:00:00Z"
        );
        let failed = Record {
            failed_at: Some("2026-09-02T00:00:00Z".into()),
            ..Default::default()
        };
        assert_eq!(judged_by(&failed), "failed 2026-09-02T00:00:00Z");
        assert_eq!(judged_by(&Record::default()), "no timestamp");
    }
}

mod prompt_tests {
    use super::deletion_prompt;

    #[test]
    fn prompt_names_what_is_deleted() {
        assert_eq!(deletion_prompt(3, 0), "Delete 3 object(s)? [y/N] ");
        assert_eq!(
            deletion_prompt(0, 2),
            "Delete 2 deployment record(s)? [y/N] "
        );
        assert_eq!(
            deletion_prompt(3, 2),
            "Delete 3 object(s) and 2 deployment record(s)? [y/N] "
        );
    }
}

mod delete_tests {
    use super::*;
    use kix::cluster::fake_api::FakeApi;
    use kix::cluster::graph::DeleteOrder;
    use kix::cluster::readiness;
    use kix::manifest::lifecycle::PHASE_ACTIVE;
    use serde_json::json;
    use std::time::Duration;

    fn rid(group: &str, kind: &str, name: &str) -> ResourceId {
        ResourceId::new(group, kind, CLUSTER_SCOPED, name)
    }

    /// Verify that `delete_resources` skips protected kinds without issuing API
    /// requests.
    #[tokio::test]
    async fn delete_resources_skips_protected_kinds() {
        let api = FakeApi::new([json!({
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": { "name": "gone" },
        })]);
        let resources = vec![
            rid(
                "apiextensions.k8s.io",
                "CustomResourceDefinition",
                "widgets.example.com",
            ),
            rid("", "Namespace", "gone"),
        ];
        let done = delete_resources(
            &api.client(),
            "a",
            DeleteOrder::unordered(resources),
            readiness::DEFAULT_TIMEOUT,
        )
        .await
        .unwrap();
        assert_eq!(done, Deletions::default());
        assert!(api.requests().is_empty(), "{:?}", api.requests());
    }

    fn record(cluster: &str, hash: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": format!("rec-{hash}"),
                "labels": { (keys::CLUSTER_LABEL): cluster },
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": PHASE_ACTIVE },
        })
    }

    fn role(name: &str, activations: &str) -> Value {
        json!({
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "ClusterRole",
            "metadata": { "name": name, "annotations": { (keys::ACTIVATIONS): activations } },
        })
    }

    /// Verify that `delete_resources` deletes unshared garbage, and keeps
    /// resources another Kix cluster deploys, including one it stamps between
    /// the guard's read and its delete.
    #[tokio::test]
    async fn delete_resources_goes_through_the_prune_guard() {
        let api = FakeApi::new([
            record("a", "a1"),
            record("b", "b1"),
            role("mine", "a1"),
            role("shared", "a1,b1"),
            role("racing", "a1"),
        ]);
        api.after_get("racing", |o| {
            o["metadata"]["annotations"][keys::ACTIVATIONS] = json!("a1,b1");
        });
        let resources = vec![
            rid("rbac.authorization.k8s.io", "ClusterRole", "mine"),
            rid("rbac.authorization.k8s.io", "ClusterRole", "shared"),
            rid("rbac.authorization.k8s.io", "ClusterRole", "racing"),
        ];
        let done = delete_resources(
            &api.client(),
            "a",
            DeleteOrder::unordered(resources),
            readiness::DEFAULT_TIMEOUT,
        )
        .await
        .unwrap();
        assert_eq!(
            done,
            Deletions {
                deleted: 1,
                failed: 0,
                changed: 0,
                held: 0,
                held_shared: 0,
                gone: HashSet::from([rid("rbac.authorization.k8s.io", "ClusterRole", "mine")]),
            }
        );
        assert_eq!(api.names("ClusterRole"), vec!["racing", "shared"]);
    }

    /// `delete_resources` deletes through the API of the object's own group,
    /// though `/apis` lists another group that serves a `Job` kind first.
    #[tokio::test]
    async fn delete_resources_deletes_through_the_objects_group() {
        use kix::cluster::fake_api::OTHER_JOB_GROUP;
        let other_version = format!("{OTHER_JOB_GROUP}/v1alpha1");
        let job = |api_version: &str| {
            json!({
                "apiVersion": api_version,
                "kind": "Job",
                "metadata": {
                    "name": "x",
                    "namespace": "default",
                    "annotations": { (keys::ACTIVATIONS): "a1" },
                },
            })
        };
        let api = FakeApi::new([record("a", "a1"), job("batch/v1"), job(&other_version)]);
        let done = delete_resources(
            &api.client(),
            "a",
            DeleteOrder::unordered(vec![rid("batch", "Job", "x")]),
            readiness::DEFAULT_TIMEOUT,
        )
        .await
        .unwrap();
        assert_eq!(done.deleted, 1);
        assert!(api.names_of("batch/v1", "Job").is_empty());
        assert_eq!(api.names_of(&other_version, "Job"), vec!["x"]);
    }

    /// gc waits for each object it deletes. One that keeps its finalizer
    /// counts as a failure and keeps the object it depends on, so gc does
    /// not forget the build they came from.
    #[tokio::test(start_paused = true)]
    async fn delete_resources_waits_and_keeps_what_a_stuck_object_needs() {
        let object = |kind: &str, name: &str, hash: &str, deps: &str, finalizers: &[&str]| {
            json!({
                "apiVersion": "v1",
                "kind": kind,
                "metadata": {
                    "name": name,
                    "namespace": "app",
                    "finalizers": finalizers,
                    "annotations": {
                        (keys::ACTIVATIONS): "a1",
                        (keys::IDENTITY_HASH): hash,
                        (keys::DEPENDS_ON): deps,
                    },
                },
            })
        };
        let cm = object(
            "ConfigMap",
            "cm",
            "hash_cm",
            "hash_s",
            &["example.com/hold"],
        );
        let secret = object("Secret", "s", "hash_s", "", &[]);
        let api = FakeApi::new([record("a", "a1"), cm.clone(), secret.clone()]);
        let start = tokio::time::Instant::now();
        let done = delete_resources(
            &api.client(),
            "a",
            DeleteOrder::of_build(&[cm.clone(), secret.clone()]),
            readiness::DEFAULT_TIMEOUT,
        )
        .await
        .unwrap();
        assert!(
            start.elapsed() >= readiness::DEFAULT_TIMEOUT,
            "{:?}",
            start.elapsed()
        );
        assert_eq!(
            done,
            Deletions {
                deleted: 0,
                failed: 1,
                changed: 0,
                held: 1,
                held_shared: 0,
                gone: HashSet::new(),
            }
        );
        assert!(!done.all_gone());
        assert_eq!(api.names("ConfigMap"), vec!["cm"]);
        assert_eq!(api.names("Secret"), vec!["s"]);

        // `--timeout 10s` gives up after ten seconds without progress.
        let api = FakeApi::new([record("a", "a1"), cm.clone(), secret.clone()]);
        let start = tokio::time::Instant::now();
        let budget = crate::commands::deploy::parse_timeout(Some("10s")).unwrap();
        let done = delete_resources(
            &api.client(),
            "a",
            DeleteOrder::of_build(&[cm, secret]),
            budget,
        )
        .await
        .unwrap();
        assert_eq!((done.failed, done.held), (1, 1));
        assert!(start.elapsed() >= budget, "{:?}", start.elapsed());
        assert!(
            start.elapsed() < Duration::from_secs(20),
            "{:?}",
            start.elapsed()
        );
    }
}

mod hard_scope_tests {
    use super::*;
    use kix::cluster::tenancy::Tenancy;
    use kix::manifest::lifecycle::PHASE_ACTIVE;
    use kube::api::DynamicObject;
    use serde_json::json;

    fn live(kind: &str, name: &str, hash: Option<&str>, activations: &str) -> DynamicObject {
        let mut annotations = serde_json::Map::new();
        if let Some(h) = hash {
            annotations.insert(keys::IDENTITY_HASH.into(), json!(h));
        }
        if !activations.is_empty() {
            annotations.insert(keys::ACTIVATIONS.into(), json!(activations));
        }
        serde_json::from_value(json!({
            "apiVersion": "v1",
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": "d",
                "annotations": annotations,
                "managedFields": [{ "manager": "kix", "operation": "Apply" }],
            },
        }))
        .unwrap()
    }

    fn record(cluster: &str, hash: &str) -> DynamicObject {
        serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": cluster,
                "labels": { (keys::CLUSTER_LABEL): cluster },
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": PHASE_ACTIVE },
        }))
        .unwrap()
    }

    fn record_in(cluster: &str, name: &str, hash: &str, phase: &str) -> DynamicObject {
        let mut r = record(cluster, hash);
        r.metadata.name = Some(name.into());
        r.data["status"]["phase"] = json!(phase);
        r
    }

    /// A full scan compares with the current record's build, but an object
    /// that a failed deploy or a deploy with `--only` wrote carries that
    /// record's hash, not the current build's. It is kept and listed under
    /// the record, not deleted, while an object only a Superseded record
    /// names is still garbage.
    #[test]
    fn hard_gc_keeps_what_failed_and_partial_deploys_wrote() {
        use kix::manifest::lifecycle::{PHASE_FAILED, PHASE_PARTIAL, PHASE_SUPERSEDED};
        let tenancy = Tenancy::fixture(
            &[
                record_in("a", "a-cur", "cur", PHASE_ACTIVE),
                record_in("a", "a-old", "old", PHASE_SUPERSEDED),
                record_in("a", "a-failed", "fail", PHASE_FAILED),
                record_in("a", "a-only", "part", PHASE_PARTIAL),
            ],
            "a",
        );
        let objects = [
            live("ConfigMap", "current", Some("h-cur"), "old,cur"),
            live("ConfigMap", "stale", Some("h-old"), "old"),
            live("ConfigMap", "from-failed", Some("h-f"), "cur,fail"),
            live("ConfigMap", "from-only", Some("h-p"), "part"),
            live("ConfigMap", "both", Some("h-b"), "fail,part"),
        ];
        let expected: HashSet<String> = ["ConfigMap/d/current".to_string()].into();
        let judged = judge_hard(&objects, &expected, &tenancy);
        assert_eq!(names(&judged.garbage), vec!["stale"]);
        let held: Vec<(&str, Vec<&str>)> = judged
            .held
            .iter()
            .map(|h| {
                (
                    h.rid.name.as_str(),
                    h.records.iter().map(String::as_str).collect(),
                )
            })
            .collect();
        assert_eq!(
            held,
            vec![
                ("from-failed", vec!["a-failed"]),
                ("from-only", vec!["a-only"]),
                ("both", vec!["a-failed", "a-only"]),
            ]
        );
        assert!(judged.shared.is_empty());
    }

    fn names(entries: &[GarbageEntry]) -> Vec<&str> {
        let mut v: Vec<&str> = entries.iter().map(|g| g.id.name.as_str()).collect();
        v.sort();
        v
    }

    /// Verify that hard GC on a shared Kubernetes cluster ignores another Kix
    /// cluster's objects, keeps shared objects, and only judges unattributed
    /// objects when `--include unattributed` is set.
    #[test]
    fn hard_gc_judges_only_this_clusters_objects() {
        let tenancy = Tenancy::fixture(&[record("a", "a2"), record("b", "b1")], "a");
        let sweep = inventory::partition_sweep(vec![
            live("ConfigMap", "a-current", Some("h-cur"), "a2"),
            live("ConfigMap", "a-stale", Some("h-old"), "a2"),
            live("ConfigMap", "b-web", Some("h-b"), "b1"),
            live("ClusterRole", "shared", Some("h-shared"), "a2,b1"),
            live("ConfigMap", "leftover", Some("h-left"), "retired"),
        ]);
        let sweep =
            inventory::scope_sweep(sweep, inventory::SweepScope::Cluster("a"), tenancy.clone());
        assert_eq!(sweep.foreign.objects, 1);
        assert_eq!(sweep.foreign.clusters, ["b".to_string()].into());
        assert_eq!(sweep.unattributed.len(), 1);

        let expected: HashSet<String> = ["ConfigMap/d/a-current".to_string()].into();
        let plan::Judged {
            garbage, shared, ..
        } = judge_hard(&sweep.managed, &expected, &tenancy);
        assert_eq!(names(&garbage), vec!["a-stale"]);
        assert_eq!(shared.len(), 1);
        assert_eq!(shared[0].rid.name, "shared");
        assert_eq!(shared[0].clusters, vec!["b".to_string()]);

        let mut with_flag = sweep.managed.clone();
        with_flag.extend(sweep.unattributed);
        let garbage = judge_hard(&with_flag, &expected, &tenancy).garbage;
        assert_eq!(names(&garbage), vec!["a-stale", "leftover"]);
    }

    /// An object that no record of any Kix cluster names, and that carries
    /// an `Apply` entry of Kix cluster `a`, is `a`'s: a full scan of `a`
    /// deletes it without `--include unattributed`. One that carries only
    /// `b`'s entry stays unattributed for `a`.
    #[test]
    fn a_full_scan_finds_an_object_only_its_entry_names() {
        let tenancy = Tenancy::fixture(&[record("a", "a2"), record("b", "b1")], "a");
        let entry_of = |cluster: &str, name: &str| {
            let mut obj = live("ConfigMap", name, Some("h-left"), "");
            obj.metadata.managed_fields = Some(vec![
                k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry {
                    manager: Some(format!("kix/{cluster}")),
                    operation: Some("Apply".into()),
                    ..Default::default()
                },
            ]);
            obj
        };
        let sweep = inventory::partition_sweep(vec![
            live("ConfigMap", "a-current", Some("h-cur"), "a2"),
            entry_of("a", "applied-by-a"),
            entry_of("b", "applied-by-b"),
        ]);
        let sweep =
            inventory::scope_sweep(sweep, inventory::SweepScope::Cluster("a"), tenancy.clone());
        let unattributed: Vec<&str> = sweep
            .unattributed
            .iter()
            .filter_map(|o| o.metadata.name.as_deref())
            .collect();
        assert_eq!(unattributed, vec!["applied-by-b"]);
        let expected: HashSet<String> = ["ConfigMap/d/a-current".to_string()].into();
        let garbage = judge_hard(&sweep.managed, &expected, &tenancy).garbage;
        assert_eq!(names(&garbage), vec!["applied-by-a"]);
    }

    /// A full scan judges by name. An object the build makes is kept,
    /// whether or not it carries a build hash, such as an object of a record
    /// an older Kix wrote whose note was edited away. One the build does
    /// not make is garbage either way.
    #[test]
    fn hard_gc_keeps_what_the_build_makes_by_name() {
        let tenancy = Tenancy::fixture(&[record("a", "a2")], "a");
        let objects = [
            live("ConfigMap", "in-build", None, "a2"),
            live("ConfigMap", "stamped", Some("h-other"), "a2"),
            live("ConfigMap", "left", None, "a2"),
        ];
        let expected: HashSet<String> = [
            "ConfigMap/d/in-build".to_string(),
            "ConfigMap/d/stamped".to_string(),
        ]
        .into();
        let judged = judge_hard(&objects, &expected, &tenancy);
        assert_eq!(names(&judged.garbage), vec!["left"]);
        assert!(
            judged
                .garbage
                .iter()
                .all(|g| g.reason == GarbageReason::NotInBuild)
        );
    }

    /// Verify that copies another program made of Kix objects, and left
    /// unowned, are excluded unless `--include copies` is set.
    #[test]
    fn hard_gc_judges_copies_only_with_the_flag() {
        let tenancy = Tenancy::fixture(&[record("a", "a2")], "a");
        let mut copy = live("Service", "web-x-guest", Some("h-guest"), "g1");
        copy.metadata.managed_fields = Some(vec![
            k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry {
                manager: Some("syncer".into()),
                operation: Some("Update".into()),
                ..Default::default()
            },
        ]);
        let sweep = || {
            inventory::scope_sweep(
                inventory::partition_sweep(vec![
                    live("ConfigMap", "a-current", Some("h-cur"), "a2"),
                    copy.clone(),
                ]),
                inventory::SweepScope::Cluster("a"),
                tenancy.clone(),
            )
        };
        let expected: HashSet<String> = ["ConfigMap/d/a-current".to_string()].into();

        let scoped = sweep();
        assert_eq!(scoped.copies.len(), 1);
        let judged = judged_objects(scoped, false, false);
        let garbage = judge_hard(&judged, &expected, &tenancy).garbage;
        assert!(garbage.is_empty());

        let judged = judged_objects(sweep(), false, true);
        let garbage = judge_hard(&judged, &expected, &tenancy).garbage;
        assert_eq!(names(&garbage), vec!["web-x-guest"]);
    }

    /// An operator's Event carries Kix's labels but no Kix annotation and no
    /// `kix` field-manager entry. `--include copies` alone judges it. An
    /// object Kix wrote that names no record is unattributed, and
    /// `--include unattributed` judges it whether or not it has a hash.
    #[test]
    fn include_copies_judges_a_copy_without_a_hash() {
        let tenancy = Tenancy::fixture(&[record("a", "a2")], "a");
        let mut event = live("Event", "db.1a2b", None, "");
        event.metadata.managed_fields = Some(vec![
            k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry {
                manager: Some("stackgres-operator".into()),
                operation: Some("Update".into()),
                ..Default::default()
            },
        ]);
        let sweep = || {
            inventory::scope_sweep(
                inventory::partition_sweep(vec![
                    live("ConfigMap", "a-current", Some("h-cur"), "a2"),
                    event.clone(),
                    live("ConfigMap", "unannotated", None, ""),
                ]),
                inventory::SweepScope::Cluster("a"),
                tenancy.clone(),
            )
        };
        let object_names = |objs: &[DynamicObject]| -> Vec<String> {
            objs.iter()
                .filter_map(|o| o.metadata.name.clone())
                .collect()
        };
        let scoped = sweep();
        assert_eq!(object_names(&scoped.copies), ["db.1a2b"]);
        assert_eq!(object_names(&scoped.unattributed), ["unannotated"]);
        let expected: HashSet<String> = ["ConfigMap/d/a-current".to_string()].into();

        let judged = judged_objects(scoped, false, true);
        let garbage = judge_hard(&judged, &expected, &tenancy).garbage;
        assert_eq!(names(&garbage), vec!["db.1a2b"]);

        let judged = judged_objects(sweep(), true, true);
        let garbage = judge_hard(&judged, &expected, &tenancy).garbage;
        assert_eq!(names(&garbage), vec!["db.1a2b", "unannotated"]);
    }

    /// Verify that hard GC does not delete another Kix cluster's objects
    /// after that cluster's records are gone. They name no record, so they are
    /// judged only with `--include unattributed`, like a leftover of this
    /// cluster whose records were retired.
    #[test]
    fn hard_gc_judges_objects_without_a_record_only_with_the_flag() {
        let tenancy = Tenancy::fixture(&[record("a", "a2")], "a");
        let sweep = || {
            inventory::scope_sweep(
                inventory::partition_sweep(vec![
                    live("ConfigMap", "a-current", Some("h-cur"), "a2"),
                    live("Service", "b-web", Some("h-b"), "b1"),
                    live("ConfigMap", "leftover", Some("h-left"), "retired"),
                ]),
                inventory::SweepScope::Cluster("a"),
                tenancy.clone(),
            )
        };
        let expected: HashSet<String> = ["ConfigMap/d/a-current".to_string()].into();

        let scoped = sweep();
        assert_eq!(scoped.unattributed.len(), 2);
        let judged = judged_objects(scoped, false, false);
        let plan::Judged {
            garbage, shared, ..
        } = judge_hard(&judged, &expected, &tenancy);
        assert!(garbage.is_empty());
        assert!(shared.is_empty());

        let judged = judged_objects(sweep(), true, false);
        let garbage = judge_hard(&judged, &expected, &tenancy).garbage;
        assert_eq!(names(&garbage), vec!["b-web", "leftover"]);
    }

    /// Verify that a full scan lists a package instance record under the
    /// instance its spec names, like the objects of that instance, even
    /// though the build stamps every record `kix.run/package: _cluster`.
    #[test]
    fn a_package_instance_record_is_listed_under_its_instance() {
        let stamped = |kind: &str, pkg: &str, pkg_ns: &str| -> DynamicObject {
            let mut obj = live(kind, "web2", Some("h-old"), "");
            let anns = obj.metadata.annotations.get_or_insert_default();
            anns.insert(keys::PACKAGE.into(), pkg.into());
            anns.insert(keys::PACKAGE_NAMESPACE.into(), pkg_ns.into());
            obj
        };
        let mut record = stamped("PackageInstance", "_cluster", "_cluster");
        record.types.as_mut().unwrap().api_version = keys::API_VERSION.into();
        record.data["spec"] = json!({ "instanceName": "web2", "namespaceName": "baseline" });
        let deployment = stamped("Deployment", "web2", "baseline");
        let tenancy = kix::cluster::tenancy::Tenancy::fixture(&[], "a");

        let garbage = judge_hard(&[record, deployment], &HashSet::new(), &tenancy).garbage;
        let packages: Vec<(Option<&str>, Option<&str>)> = garbage
            .iter()
            .map(|g| (g.package_namespace.as_deref(), g.package.as_deref()))
            .collect();
        assert_eq!(
            packages,
            vec![
                (Some("baseline"), Some("web2")),
                (Some("baseline"), Some("web2"))
            ]
        );
    }
}

mod live_order_tests {
    use super::*;
    use serde_json::json;

    fn live(kind: &str, name: &str, hash: &str, deps: &str) -> kube::api::DynamicObject {
        serde_json::from_value(json!({
            "apiVersion": "v1",
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": "app",
                "annotations": {
                    (keys::IDENTITY_HASH): hash,
                    (keys::DEPENDS_ON): deps,
                },
            },
            "data": { "secret": "c2VjcmV0" },
        }))
        .unwrap()
    }

    fn entry(kind: &str, name: &str) -> GarbageEntry {
        GarbageEntry {
            id: ResourceId::new("", kind, "app", name),
            identity_hash: None,
            package: None,
            package_namespace: None,
            reason: GarbageReason::NotInBuild,
            deleting: None,
        }
    }

    /// A full scan of a Kix cluster whose records an older Kix wrote orders
    /// its garbage by the notes on the live objects, also through an object
    /// it keeps: `cm` needs `kept`, which needs `secret`, so a stuck `cm`
    /// holds `secret` back.
    #[test]
    fn a_full_scan_of_an_older_kixs_records_orders_by_the_notes() {
        let objects = [
            live("ConfigMap", "cm", "h_cm", "h_kept"),
            live("ConfigMap", "kept", "h_kept", "h_secret"),
            live("Secret", "secret", "h_secret", ""),
        ];
        let mut order = live_order(
            &objects,
            &[entry("Secret", "secret"), entry("ConfigMap", "cm")],
            &Tenancy::fixture(&[], "a"),
        );
        let names: Vec<&str> = order.ids().iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, vec!["cm", "secret"]);
        order.hold_back(&ResourceId::new("", "ConfigMap", "app", "cm"));
        assert!(
            order
                .held_by(&ResourceId::new("", "Secret", "app", "secret"))
                .is_some()
        );
    }

    /// The ordering keeps only names and the two dependency annotations, so
    /// no Secret data is copied.
    #[test]
    fn the_ordering_stub_carries_no_data() {
        let stub = ordering_stub(&live("Secret", "s", "h_s", ""));
        assert!(stub.get("data").is_none(), "{stub}");
        assert_eq!(
            stub["metadata"]["annotations"][keys::IDENTITY_HASH],
            json!("h_s")
        );
        assert_eq!(
            ResourceId::from_value(&stub),
            ResourceId::new("", "Secret", "app", "s")
        );
    }
}

mod lock_tests {
    use super::*;
    use kix::cluster::fake_api::FakeApi;
    use kix::cluster::head;
    use serde_json::json;

    fn record(name: &str, phase: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": lifecycle::RECORD_KIND,
            "metadata": {
                "name": name,
                "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): "c" },
            },
            "status": { "phase": phase },
        })
    }

    fn policy() -> RetentionPolicy {
        RetentionPolicy {
            keep_min: 0,
            keep_max: 0,
            keep_for: None,
            now: chrono::Utc::now(),
        }
    }

    async fn retirement(api: &FakeApi) -> RecordRetirement {
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open(&client, &discovery).unwrap().into_records();
        plan_records_with(records, "c", &policy()).await.unwrap()
    }

    /// gc binds to the generation of the deploy lock it read with the
    /// records, refuses once another run has changed the cluster since,
    /// holds the lock as `gc`, and writes the records through it.
    #[tokio::test]
    async fn gc_holds_the_deploy_lock_it_read() {
        let api = FakeApi::new([
            record("cur", "Active"),
            record("old", "Superseded"),
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": head::KIND,
                "metadata": { "name": "c" },
                "status": { "current": "cur", "generation": 2 },
            }),
        ]);
        let client = api.client();
        let mut stale = retirement(&api).await;
        api.patch_object(head::KIND, "c", |o| o["status"]["generation"] = json!(3));
        let err = stale.lock(&client, "c").await.unwrap_err();
        assert!(err.to_string().contains("changed after this plan"), "{err}");

        let mut fresh = retirement(&api).await;
        assert_eq!(fresh.plan.retire.len(), 1);
        let lock = fresh.lock(&client, "c").await.unwrap();
        let held = &api.object(head::KIND, "c").unwrap()["status"]["lock"];
        assert_eq!(held["purpose"], "gc");
        let (retired, failed) = delete_records(&fresh).await.unwrap();
        assert_eq!((retired, failed), (1, 0));
        assert!(lock.wrote(), "the records were written through the lock");
        crate::commands::lock::release(&lock).await;
        let status = &api.object(head::KIND, "c").unwrap()["status"];
        assert_eq!(status["generation"], 4);
        assert_eq!(status["writer"]["program"], "cli");
    }

    /// gc refuses when a newer minor of Kix wrote to the cluster last, as
    /// the head names it, and passes when this Kix did.
    #[tokio::test]
    async fn gc_by_an_older_kix_than_the_last_writer_is_refused() {
        let head = |version: &str| {
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": head::KIND,
                "metadata": { "name": "c" },
                "status": {
                    "current": "cur",
                    "generation": 1,
                    "writer": { "version": version, "program": "cli" },
                },
            })
        };
        let newer = FakeApi::new([record("cur", "Active"), head("99.0.0")]);
        assert!(retirement(&newer).await.check_writer("c").is_err());
        let same = FakeApi::new([
            record("cur", "Active"),
            head(&kix::version::running().to_string()),
        ]);
        assert!(retirement(&same).await.check_writer("c").is_ok());
    }
}

mod revision_tests {
    use super::*;
    use kix::cluster::fake_api::FakeApi;
    use kix::cluster::tenancy_fixture::{Rec, State, Written, state};
    use kix::manifest::lifecycle::{PHASE_ACTIVE, PHASE_PARTIAL};
    use serde_json::json;

    /// Kix cluster `a`: its current record kept two orphans, and a deploy
    /// with `--only` of the next build added one of them back.
    fn recs() -> Vec<Rec<'static>> {
        vec![
            Rec {
                name: "a-cur",
                cluster: "a",
                hash: "cur",
                phase: PHASE_ACTIVE,
                current: true,
                objects: &["web"],
                kept: &["left", "stuck", "added"],
                ..Rec::default()
            },
            Rec {
                name: "a-only",
                cluster: "a",
                hash: "part",
                phase: PHASE_PARTIAL,
                objects: &["web", "added"],
                ..Rec::default()
            },
        ]
    }

    fn names(entries: &[GarbageEntry]) -> Vec<&str> {
        let mut v: Vec<&str> = entries.iter().map(|g| g.id.name.as_str()).collect();
        v.sort();
        v
    }

    /// A full scan judges the same from records and from revisions: an
    /// object only the kept orphans list is garbage, and one a `Partial`
    /// record also names is held for that record.
    #[test]
    fn a_full_scan_judges_the_same_from_either_source() {
        for written in [Written::Records, Written::Revisions] {
            let state = state(&recs(), |_| written);
            let tenancy = state.tenancy("a");
            let live: Vec<_> = ["web", "left", "stuck", "added"]
                .iter()
                .map(|n| state.object(n))
                .collect();
            let expected: HashSet<String> = [plan::live_identity(&state.object("web"))].into();
            let judged = judge_hard(&live, &expected, &tenancy);
            assert_eq!(names(&judged.garbage), ["left", "stuck"], "{written:?}");
            let held: Vec<(&str, &[String])> = judged
                .held
                .iter()
                .map(|h| (h.rid.name.as_str(), h.records.as_slice()))
                .collect();
            assert_eq!(
                held,
                [("added", &["a-only".to_string()][..])],
                "{written:?}"
            );
        }
    }

    /// Return the state of Kix cluster `a` whose current record kept a
    /// custom resource `a-widget` (written as a ConfigMap) and the operator
    /// that removes its finalizer, with the kept-orphans revision recording
    /// that `a-widget` needs `operator`, and with neither live object carrying
    /// `kix.run/depends-on` or `kix.run/identity-hash`.
    fn kept_widget_and_operator() -> State {
        use kix::cluster::revision::{Need, Revision, RevisionObject, RevisionSpec, Slot};
        let recs = [Rec {
            name: "a-cur",
            cluster: "a",
            hash: "cur",
            phase: PHASE_ACTIVE,
            current: true,
            objects: &["web"],
            kept: &["a-widget", "operator"],
            ..Rec::default()
        }];
        let mut state = state(&recs, |_| Written::Revisions);
        let rid = |name: &str| ResourceId::new("", "ConfigMap", "d", name);
        let entry = |name: &str| RevisionObject::of_id(&format!("h-{name}"), &rid(name));
        let kept = Revision::new(RevisionSpec::new(
            "a",
            Slot::KeptOrphans,
            vec![
                entry("a-widget").with_needs([Need::of(&rid("operator"), Some("controller"))]),
                entry("operator"),
            ],
        ));
        let old = state.revision_named("a-cur", "keptOrphans");
        state.remove_revision(&old);
        state
            .revisions
            .push(kix::cluster::tenancy_fixture::revision_value(&kept));
        state.records[0]["status"]["revisions"]["keptOrphans"] = json!(kept.name);
        for object in &mut state.objects {
            let annotations = object["metadata"]["annotations"].as_object_mut().unwrap();
            annotations.remove(keys::IDENTITY_HASH);
            annotations.remove(keys::DEPENDS_ON);
        }
        state
    }

    /// Without edges, the order of two unrelated ConfigMaps is the reverse
    /// of their names, so `operator` would come before `a-widget`.
    fn position(order: &DeleteOrder, name: &str) -> usize {
        order.ids().iter().position(|r| r.name == name).unwrap()
    }

    /// The default mode takes the edges of kept orphans from the
    /// kept-orphans revision, so it deletes the custom resource before the
    /// operator that removes its finalizer.
    #[test]
    fn the_default_mode_orders_kept_orphans_by_the_revisions() {
        let state = kept_widget_and_operator();
        let garbage: Vec<Value> = ["operator", "a-widget"]
            .iter()
            .map(|n| kix::manifest::types::to_manifest_value(&state.object(n)))
            .collect();
        let order = soft_order(Vec::new(), &garbage, &state.tenancy("a"));
        assert!(position(&order, "a-widget") < position(&order, "operator"));
    }

    /// A full scan takes the edges from the revisions too.
    #[test]
    fn a_full_scan_orders_kept_orphans_by_the_revisions() {
        let state = kept_widget_and_operator();
        let live: Vec<_> = ["operator", "a-widget"]
            .iter()
            .map(|n| state.object(n))
            .collect();
        let entry = |name: &str| GarbageEntry {
            id: ResourceId::new("", "ConfigMap", "d", name),
            identity_hash: None,
            package: None,
            package_namespace: None,
            reason: GarbageReason::NotInBuild,
            deleting: None,
        };
        let order = live_order(
            &live,
            &[entry("operator"), entry("a-widget")],
            &state.tenancy("a"),
        );
        assert!(position(&order, "a-widget") < position(&order, "operator"));
    }

    async fn retirement_of(api: &FakeApi) -> RecordRetirement {
        let client = api.client();
        let discovery = kix::cluster::discovery::discover_resources(&client)
            .await
            .unwrap();
        let records = Records::open(&client, &discovery)
            .unwrap()
            .into_records()
            .unwrap();
        let active = records.get("a-cur").await.unwrap();
        RecordRetirement {
            records: Some(records),
            plan: Default::default(),
            active,
            head: None,
        }
    }

    fn objects_update(state: &State) -> KeptUpdate {
        let tenancy = state.tenancy("a");
        let active = Record::of(&serde_json::from_value(state.records[0].clone()).unwrap());
        let Kept::Objects(listed) = tenancy.kept(&active) else {
            panic!("a is read from revisions");
        };
        KeptUpdate::Objects {
            listed: listed.into_iter().cloned().collect(),
            imports: Vec::new(),
            live: ["left", "stuck", "added"]
                .map(|n| ResourceId::new("", "ConfigMap", "d", n))
                .into(),
            unknown: HashSet::new(),
            in_build: HashSet::new(),
        }
    }

    /// gc removes a kept entry only when the object is known to be gone or
    /// its delete reported it gone. An entry whose kind the read could not
    /// list, or the cluster does not serve now, stays, even when gc deletes
    /// nothing.
    #[test]
    fn gc_keeps_an_entry_it_could_not_read() {
        let state = state(&recs(), |_| Written::Revisions);
        let KeptUpdate::Objects {
            listed, in_build, ..
        } = objects_update(&state)
        else {
            panic!("objects");
        };
        let unread: HashSet<ResourceId> = listed.iter().map(|o| o.resource_id()).collect();
        let update = KeptUpdate::Objects {
            listed: listed.clone(),
            imports: Vec::new(),
            live: HashSet::new(),
            unknown: unread,
            in_build,
        };
        assert_eq!(update.remaining(&HashSet::new()), None);
        let gone: HashSet<ResourceId> = [listed[0].resource_id()].into();
        assert_eq!(
            update.remaining(&gone).map(|r| r.len()),
            Some(listed.len() - 1)
        );
    }

    /// gc that deleted some of the kept orphans writes a kept-orphans
    /// revision of what remains and names it on the current record. gc that
    /// deleted all of them removes the name.
    #[tokio::test]
    async fn gc_rewrites_the_kept_orphans_revision_to_what_remains() {
        let state = state(&recs(), |_| Written::Revisions);
        let api = FakeApi::new(state.all());
        let retirement = retirement_of(&api).await;
        let update = objects_update(&state);
        let done = Deletions {
            deleted: 1,
            gone: [ResourceId::new("", "ConfigMap", "d", "left")].into(),
            ..Deletions::default()
        };
        update_kept("a", &retirement, &update, &done).await.unwrap();
        let record = api.object("Activation", "a-cur").unwrap();
        let named = record["status"]["revisions"]["keptOrphans"]
            .as_str()
            .unwrap()
            .to_string();
        assert_ne!(named, state.revision_named("a-cur", "keptOrphans"));
        let revision = api
            .object(kix::cluster::revision::KIND, &named)
            .expect("the new kept-orphans revision");
        let kept: Vec<&str> = revision["spec"]["objects"]
            .as_array()
            .unwrap()
            .iter()
            .map(|o| o["name"].as_str().unwrap())
            .collect();
        assert_eq!(kept, ["added", "stuck"]);

        let retirement = retirement_of(&api).await;
        let done = Deletions {
            gone: ["left", "stuck", "added"]
                .map(|n| ResourceId::new("", "ConfigMap", "d", n))
                .into(),
            ..Deletions::default()
        };
        update_kept("a", &retirement, &update, &done).await.unwrap();
        let record = api.object("Activation", "a-cur").unwrap();
        assert!(record["status"]["revisions"]["keptOrphans"].is_null());
    }

    /// gc refuses before it deletes anything when a revision a record names
    /// is missing.
    #[tokio::test]
    async fn gc_refuses_when_a_named_revision_is_missing() {
        let mut state = state(&recs(), |_| Written::Revisions);
        let missing = state.revision_named("a-only", "instance");
        state.remove_revision(&missing);
        let api = FakeApi::new(state.all());
        let retirement = retirement_of(&api).await;
        let err = read_tenancy(retirement.records.as_ref().unwrap(), "a")
            .await
            .unwrap_err()
            .to_string();
        assert!(
            err.contains(&missing) && err.contains("a-only") && err.contains("Nothing was deleted"),
            "{err}"
        );
    }

    /// With its kept-orphans revision gone, a full scan rebuilds the list
    /// from the live objects the Kix cluster applied that no other revision
    /// of it names and the build lacks. The rebuilt list is written only
    /// under a lock taken at the generation the scan read.
    #[tokio::test]
    async fn gc_rebuilds_a_missing_kept_orphans_list() {
        let mut state = state(&recs(), |_| Written::Revisions);
        let kept = state.revision_named("a-cur", "keptOrphans");
        state.remove_revision(&kept);
        let api = FakeApi::new(state.all());
        for name in ["left", "stuck", "added"] {
            api.patch_object("ConfigMap", name, |o| {
                o["metadata"]["managedFields"][0]["manager"] = json!("kix/a");
            });
        }
        let client = api.client();
        let discovery = kix::cluster::discovery::discover_resources(&client)
            .await
            .unwrap();
        let opened = Records::open(&client, &discovery).unwrap();
        let sweep = inventory::sweep_managed(
            &client,
            &discovery,
            &opened,
            inventory::SweepScope::Cluster("a"),
        )
        .await
        .unwrap();
        assert!(sweep.tenancy.only_kept_unreadable());
        let in_build: HashSet<ResourceId> = [ResourceId::new("", "ConfigMap", "d", "web")].into();
        let objects = keep::kept_to_rebuild(&sweep, &in_build);
        let rebuilt: Vec<&str> = objects.iter().map(|o| o.name.as_str()).collect();
        // `added` is named by the `Partial` record, so it is not a kept
        // orphan.
        assert_eq!(rebuilt, ["left", "stuck"]);
        // Nothing says which build wanted each object, and the live objects
        // carry no build hash, so the list names them with a hash no object
        // hash equals.
        assert!(
            objects
                .iter()
                .all(|o| o.hash == kix::cluster::revision::REBUILT && o.needs.is_empty())
        );

        let records = opened.into_records().unwrap();
        let generation = kix::cluster::head::generation_of(
            kix::cluster::head::read(&client, "a")
                .await
                .unwrap()
                .as_ref(),
        );
        let moved = write_rebuilt(
            &client,
            &records,
            "a",
            "a-cur",
            objects.clone(),
            generation + 1,
        )
        .await;
        assert!(moved.is_err());
        assert!(
            api.object("Activation", "a-cur").unwrap()["status"]["revisions"]["keptOrphans"]
                == json!(kept)
        );
        let name = write_rebuilt(&client, &records, "a", "a-cur", objects, generation)
            .await
            .unwrap();
        assert_eq!(
            api.object("Activation", "a-cur").unwrap()["status"]["revisions"]["keptOrphans"],
            json!(name)
        );
    }

    /// Return the state that `kix deploy a` without `--prune` leaves on a
    /// Kubernetes cluster an older Kix deployed: the current record of `a`
    /// keeps the import marker `platform-dns`, which left the build, in its
    /// kept-orphans revision. With `older`, Kix cluster `b`, which an older
    /// Kix deployed, still names the marker, so it keeps its notes.
    fn leftover_marker(older: bool) -> State {
        use kix::cluster::revision::{Revision, RevisionObject, RevisionSpec, Slot};
        let mut recs = vec![Rec {
            name: "a-cur",
            cluster: "a",
            hash: "cur",
            phase: PHASE_ACTIVE,
            current: true,
            objects: &["web"],
            kept: &["platform-dns"],
            ..Rec::default()
        }];
        if older {
            recs.push(Rec {
                name: "b-cur",
                cluster: "b",
                hash: "bcur",
                phase: PHASE_ACTIVE,
                current: true,
                objects: &["platform-dns"],
                ..Rec::default()
            });
        }
        let mut state = state(&recs, |c| {
            if c == "a" {
                Written::Revisions
            } else {
                Written::Records
            }
        });
        let marker = state
            .objects
            .iter_mut()
            .find(|o| o["metadata"]["name"] == "platform-dns")
            .unwrap();
        marker["apiVersion"] = json!(keys::API_VERSION);
        marker["kind"] = json!("PackageInstance");
        let notes = marker["metadata"]["annotations"].as_object_mut().unwrap();
        notes.insert(keys::MODE.into(), json!("import"));
        notes.insert(keys::IMPORT_API_VERSION.into(), json!("v1"));
        notes.insert(keys::IMPORT_KIND.into(), json!("Service"));
        notes.insert(keys::IMPORT_NAME.into(), json!("kube-dns"));
        let mut managers = vec![json!({
            "manager": "kix/a",
            "operation": "Apply",
            "apiVersion": keys::API_VERSION,
        })];
        if older {
            managers.push(json!({
                "manager": "kix",
                "operation": "Apply",
                "apiVersion": keys::API_VERSION,
            }));
        } else {
            notes.remove(keys::IDENTITY_HASH);
        }
        marker["metadata"]["managedFields"] = json!(managers);
        let kept = Revision::new(RevisionSpec::new(
            "a",
            Slot::KeptOrphans,
            vec![RevisionObject::of_id(
                "h-platform-dns",
                &ResourceId::new(keys::GROUP, "PackageInstance", "d", "platform-dns"),
            )],
        ));
        let old = state.revision_named("a-cur", "keptOrphans");
        state.remove_revision(&old);
        state
            .revisions
            .push(kix::cluster::tenancy_fixture::revision_value(&kept));
        state.records[0]["status"]["revisions"]["keptOrphans"] = json!(kept.name);
        state
    }

    /// Return the build of `a`: the ConfigMap `web` and the marker
    /// `platform-dns` as an import, which Kix writes no object for.
    fn build_with_marker(state: &State) -> StoreGraph {
        let manifests: Vec<Value> = ["web", "platform-dns"]
            .iter()
            .map(|n| kix::manifest::types::to_manifest_value(&state.object(n)))
            .collect();
        StoreGraph::synthesize(&manifests, &StoreGraph::empty("a"))
    }

    /// Run a soft gc of `a` against `graph` as `kix gc a --yes` does: judge
    /// the kept orphans, keep what another Kix cluster still deploys, delete
    /// the rest, and rewrite the kept-orphans list. Return the garbage and
    /// what was kept as shared.
    async fn soft_gc(api: &FakeApi, graph: &StoreGraph) -> (Vec<String>, Vec<String>) {
        let client = api.client();
        let retirement = retirement_of(api).await;
        let records = retirement.records.as_ref().unwrap();
        let tenancy = read_tenancy(records, "a").await.unwrap();
        let discovery = kix::cluster::discovery::discover_resources(&client)
            .await
            .unwrap();
        let active = retirement.active.clone().unwrap();
        let kept = baseline::kept_of(
            &client,
            &discovery,
            &tenancy,
            &active,
            None,
            &Default::default(),
            &|_| {},
            None,
        )
        .await
        .unwrap();
        let (garbage, update) = judge_soft(graph, &kept, active.identity_hash.as_deref());
        let rids: Vec<ResourceId> = garbage.iter().map(ResourceId::from_value).collect();
        let (rids, shared) = kix::plan::keep_shared(&client, "a", rids).await.unwrap();
        let done = delete_resources(
            &client,
            "a",
            DeleteOrder::unordered(rids),
            std::time::Duration::from_secs(5),
        )
        .await
        .unwrap();
        update_kept("a", &retirement, &update, &done).await.unwrap();
        (
            garbage
                .iter()
                .map(|m| m["metadata"]["name"].as_str().unwrap().to_string())
                .collect(),
            shared.iter().map(|s| s.rid.name.clone()).collect(),
        )
    }

    /// Return the names the current record's kept-orphans revision lists,
    /// or none when it names no such revision.
    fn kept_names(api: &FakeApi) -> Vec<String> {
        let record = api.object("Activation", "a-cur").unwrap();
        let Some(name) = record["status"]["revisions"]["keptOrphans"].as_str() else {
            return Vec::new();
        };
        api.object(kix::cluster::revision::KIND, name).unwrap()["spec"]["objects"]
            .as_array()
            .unwrap()
            .iter()
            .map(|o| o["name"].as_str().unwrap().to_string())
            .collect()
    }

    /// The build still holds the marker `platform-dns`, but Kix writes no
    /// object for it, so the marker an older Kix applied is a kept orphan
    /// like any other. `kix gc` deletes it and then lists nothing kept.
    #[tokio::test]
    async fn gc_deletes_a_leftover_marker() {
        let state = leftover_marker(false);
        let api = FakeApi::new(state.all());
        let graph = build_with_marker(&state);
        assert_eq!(kept_names(&api), ["platform-dns"]);
        let (garbage, shared) = soft_gc(&api, &graph).await;
        assert_eq!(garbage, ["platform-dns"]);
        assert!(shared.is_empty());
        assert!(api.object("PackageInstance", "platform-dns").is_none());
        assert!(kept_names(&api).is_empty());
    }

    /// A leftover marker that another Kix cluster, deployed by an older Kix,
    /// still names is kept, and the kept-orphans list still names it, so a
    /// later gc deletes it once that Kix cluster lets it go.
    #[tokio::test]
    async fn gc_keeps_a_leftover_marker_an_older_kix_cluster_still_names() {
        let state = leftover_marker(true);
        let api = FakeApi::new(state.all());
        let graph = build_with_marker(&state);
        let (garbage, shared) = soft_gc(&api, &graph).await;
        assert_eq!(garbage, ["platform-dns"]);
        assert_eq!(shared, ["platform-dns"]);
        assert!(api.object("PackageInstance", "platform-dns").is_some());
        assert_eq!(kept_names(&api), ["platform-dns"]);
    }

    /// A full scan judges a marker the build holds as an object that left
    /// the build, so it finds a marker an older Kix left that no record names
    /// any more, by its field manager.
    #[test]
    fn a_full_scan_judges_a_leftover_marker_as_not_in_the_build() {
        let state = leftover_marker(false);
        let graph = build_with_marker(&state);
        let live = [state.object("web"), state.object("platform-dns")];
        let judged = judge_hard(&live, &identities(&graph), &state.tenancy("a"));
        assert_eq!(names(&judged.garbage), ["platform-dns"]);
    }

    /// A cluster that an earlier gc left with a marker no record names: the
    /// marker is on the cluster under `kix/a`, and the current record names
    /// no kept-orphans revision. A full scan finds it by its field manager
    /// as this cluster's object that left the build, and deletes it without
    /// `--include unattributed`.
    #[test]
    fn a_full_scan_finds_a_marker_no_record_names_by_its_entry() {
        let mut state = leftover_marker(false);
        let old = state.revision_named("a-cur", "keptOrphans");
        state.remove_revision(&old);
        state.records[0]["status"]["revisions"]["keptOrphans"] = Value::Null;
        let graph = build_with_marker(&state);
        let tenancy = state.tenancy("a");
        let scoped = inventory::scope_sweep(
            inventory::partition_sweep(vec![state.object("web"), state.object("platform-dns")]),
            inventory::SweepScope::Cluster("a"),
            tenancy.clone(),
        );
        assert!(scoped.unattributed.is_empty());
        let expected = identities(&graph);
        let without = judged_objects(scoped, false, false);
        assert_eq!(
            names(&judge_hard(&without, &expected, &tenancy).garbage),
            ["platform-dns"]
        );
    }
}
