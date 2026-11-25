use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use kix::cluster::activation::{Record, RetentionPolicy, RetireReason, retire_plan};
use kix::manifest::types::CLUSTER_SCOPED;

use super::*;

mod soft_garbage_tests {
    use super::*;
    use serde_json::json;

    fn path(hash32: &str, name: &str) -> PathBuf {
        PathBuf::from(format!("/nix/store/{hash32}-{name}"))
    }

    #[test]
    fn only_resources_absent_by_identity_are_garbage() {
        let record = json!({"kind": lifecycle::RECORD_KIND, "metadata": {"name": "stage1-aaaa"}});
        let removed = json!({"kind": "ConfigMap", "metadata": {"name": "old", "namespace": "d"}});
        let changed = json!({"kind": "Deployment", "metadata": {"name": "web", "namespace": "d"}});
        let old_record_path = path("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "activation");
        let old_cm_path = path("cccccccccccccccccccccccccccccccc", "configmap");
        let old_dep_path = path("dddddddddddddddddddddddddddddddd", "deployment");
        let old = vec![
            (&old_record_path, &record),
            (&old_cm_path, &removed),
            (&old_dep_path, &changed),
        ];
        // The new build: a different record hash, the Deployment with new
        // content (new hash, same name), and no ConfigMap.
        let new_hashes: HashSet<String> = [
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".to_string(),
            "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee".to_string(),
        ]
        .into();
        let new_ids: HashSet<String> = ["Deployment/d/web".to_string()].into();
        let garbage = soft_garbage(old, &new_hashes, &new_ids);
        assert_eq!(
            garbage.keys().collect::<Vec<_>>(),
            vec!["cccccccccccccccccccccccccccccccc"],
            "the changed Deployment and the rebuilt record are not garbage: {garbage:?}"
        );
    }
}

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
                json!({"kind": lifecycle::RECORD_KIND, "metadata": {"name": "c-v1", "annotations": { keys::IDENTITY_HASH: "h2" }}}),
            ],
            vec![m("ConfigMap", "old", "h1"), m("Secret", "listed", "h3")],
        ];
        let new_hashes: HashSet<String> = ["h9".to_string()].into();
        let new_ids: HashSet<String> = ["Deployment/d/web".to_string()].into();
        let mut already = HashMap::new();
        already.insert("h3".to_string(), m("Secret", "listed", "h3"));

        let got: Vec<String> = kept_garbage(&kept, &already, &new_hashes, &new_ids)
            .iter()
            .map(k8s_identity)
            .collect();
        assert_eq!(got, vec!["ConfigMap/d/old"]);
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
        assert!(!may_clear_kept(&active(false), true, Some("h-v2")));
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

    /// Verify that `delete_resources` deletes unshared garbage, keeps resources
    /// still deployed by another Kix cluster, and records resources modified
    /// concurrently as `changed`.
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
                changed: 1,
                held: 0,
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
            DeleteOrder::of_manifests(&[cm.clone(), secret.clone()]),
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
            DeleteOrder::of_manifests(&[cm, secret]),
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
        assert_eq!(sweep.foreign.get("b"), Some(&1));
        assert_eq!(sweep.unattributed.len(), 1);

        let expected: HashSet<String> = ["h-cur".to_string()].into();
        let (garbage, shared) = judge_hard(&sweep.managed, &expected, &HashSet::new(), &tenancy);
        assert_eq!(names(&garbage), vec!["a-stale"]);
        assert_eq!(shared.len(), 1);
        assert_eq!(shared[0].rid.name, "shared");
        assert_eq!(shared[0].clusters, vec!["b".to_string()]);

        let mut with_flag = sweep.managed.clone();
        with_flag.extend(sweep.unattributed);
        let (garbage, _) = judge_hard(&with_flag, &expected, &HashSet::new(), &tenancy);
        assert_eq!(names(&garbage), vec!["a-stale", "leftover"]);
    }

    /// Verify that controller-created copies of Kix objects are excluded unless
    /// `--include copies` is set.
    #[test]
    fn hard_gc_judges_copies_only_with_the_flag() {
        let tenancy = Tenancy::fixture(&[record("a", "a2")], "a");
        let mut copy = live("Service", "web-x-guest", Some("h-guest"), "g1");
        copy.metadata.owner_references = Some(vec![
            k8s_openapi::apimachinery::pkg::apis::meta::v1::OwnerReference {
                api_version: "v1".into(),
                kind: "Service".into(),
                name: "syncer".into(),
                uid: "u".into(),
                ..Default::default()
            },
        ]);
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
        let expected: HashSet<String> = ["h-cur".to_string()].into();

        let scoped = sweep();
        assert_eq!(scoped.copies.len(), 1);
        let judged = judged_objects(scoped, false, false);
        let (garbage, _) = judge_hard(&judged, &expected, &HashSet::new(), &tenancy);
        assert!(garbage.is_empty());

        let judged = judged_objects(sweep(), false, true);
        let (garbage, _) = judge_hard(&judged, &expected, &HashSet::new(), &tenancy);
        assert_eq!(names(&garbage), vec!["web-x-guest"]);
    }

    /// Verify that on a single-cluster target, objects referencing only retired
    /// Activation records are judged as garbage without extra flags.
    #[test]
    fn hard_gc_on_a_single_cluster_is_unchanged() {
        let tenancy = Tenancy::fixture(&[record("a", "a2")], "a");
        let sweep = inventory::partition_sweep(vec![
            live("ConfigMap", "a-current", Some("h-cur"), "a2"),
            live("ConfigMap", "leftover", Some("h-left"), "retired"),
        ]);
        let sweep =
            inventory::scope_sweep(sweep, inventory::SweepScope::Cluster("a"), tenancy.clone());
        assert!(sweep.unattributed.is_empty());
        let expected: HashSet<String> = ["h-cur".to_string()].into();
        let (garbage, shared) = judge_hard(&sweep.managed, &expected, &HashSet::new(), &tenancy);
        assert_eq!(names(&garbage), vec!["leftover"]);
        assert!(shared.is_empty());
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
            activations: None,
            reason: GarbageReason::HashNotExpected,
            deleting: None,
        }
    }

    /// A full scan orders its garbage by the live objects' dependencies, also
    /// through an object it keeps: `cm` needs `kept`, which needs `secret`,
    /// so a stuck `cm` holds `secret` back.
    #[test]
    fn a_full_scan_orders_by_live_dependencies() {
        let objects = [
            live("ConfigMap", "cm", "h_cm", "h_kept"),
            live("ConfigMap", "kept", "h_kept", "h_secret"),
            live("Secret", "secret", "h_secret", ""),
        ];
        let mut order = live_order(
            &objects,
            &[entry("Secret", "secret"), entry("ConfigMap", "cm")],
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
