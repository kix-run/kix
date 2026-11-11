use kix::manifest::types::ResourceId;

use super::*;

mod prune_start_and_timeout_tests {
    use super::*;

    fn orphans() -> Vec<ResourceId> {
        vec![
            ResourceId {
                kind: "ConfigMap".into(),
                name: "old".into(),
                namespace: "app".into(),
            },
            ResourceId {
                kind: "Namespace".into(),
                name: "gone".into(),
                namespace: kix::manifest::types::CLUSTER_SCOPED.into(),
            },
        ]
    }

    /// Verify that the warn-only prune section lists a protected Namespace
    /// orphan separately from reported orphans.
    #[test]
    fn prune_section_lists_kept_orphans_apart() {
        let all = orphans();
        let text = render_prune_start(&all[..1], &all[1..], false);
        assert!(
            text.contains("1 orphaned resources kept (warn-only"),
            "{text}"
        );
        assert!(text.contains("- ConfigMap/old@app"), "{text}");
        assert!(
            text.contains(
                "1 orphaned resources are never deleted automatically\n  ! Namespace/gone"
            ),
            "{text}"
        );
    }

    #[test]
    fn parse_timeout_none() {
        let t = parse_timeout(None).unwrap();
        assert_eq!(t, readiness::DEFAULT_TIMEOUT);
    }

    #[test]
    fn parse_timeout_seconds() {
        assert_eq!(parse_timeout(Some("60s")).unwrap(), Duration::from_secs(60));
    }

    #[test]
    fn parse_timeout_minutes() {
        assert_eq!(parse_timeout(Some("5m")).unwrap(), Duration::from_secs(300));
    }

    #[test]
    fn parse_timeout_plain_number() {
        assert_eq!(
            parse_timeout(Some("120")).unwrap(),
            Duration::from_secs(120)
        );
    }

    #[test]
    fn parse_timeout_invalid() {
        assert!(parse_timeout(Some("abc")).is_err());
    }
}

mod prune_flag_tests {
    use crate::cli::{Cli, Command};
    use clap::Parser;
    use kix::cluster::scheduler::PrunePolicy;

    fn prune_policy(extra: &[&str]) -> PrunePolicy {
        let argv = [&["kix", "deploy", "x"][..], extra].concat();
        let Command::Deploy(args) = Cli::try_parse_from(argv).expect("args parse").command else {
            unreachable!()
        };
        super::flags_of(&args.plan).prune_policy()
    }

    #[test]
    fn prune_policy_follows_the_flags() {
        assert_eq!(prune_policy(&[]), PrunePolicy::WarnOnly);
        assert_eq!(prune_policy(&["--prune"]), PrunePolicy::Delete);
        assert_eq!(
            prune_policy(&["--prune", "--prune-mode", "default"]),
            PrunePolicy::Delete
        );
        assert_eq!(
            prune_policy(&["--prune-mode", "default"]),
            PrunePolicy::WarnOnly
        );
        assert_eq!(
            prune_policy(&["--prune", "--prune-mode", "no"]),
            PrunePolicy::Skip
        );
    }

    /// Verify that `--prune-mode` rejects `eager`.
    #[test]
    fn eager_is_no_longer_a_prune_mode() {
        let err = match Cli::try_parse_from(["kix", "deploy", "x", "--prune-mode", "eager"]) {
            Ok(_) => panic!("eager must not parse"),
            Err(e) => e,
        };
        assert_eq!(err.kind(), clap::error::ErrorKind::InvalidValue);
    }
}

mod cached_baseline_tests {
    use super::*;
    use kix::cluster::fake_api::FakeApi;
    use kix::manifest::keys;
    use kix::manifest::lifecycle;
    use kix::manifest::lifecycle::PHASE_ACTIVE;
    use serde_json::json;

    fn record(cluster: &str, hash: &str, phase: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": lifecycle::RECORD_KIND,
            "metadata": {
                "name": format!("rec-{hash}"),
                "labels": {
                    "app.kubernetes.io/managed-by": "kix",
                    (keys::CLUSTER_LABEL): cluster,
                },
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": phase },
        })
    }

    /// Verify that `check_cached_baseline` rejects a cached build whose hash
    /// does not match the context's Active record or when no Active record exists.
    #[tokio::test]
    async fn a_cached_build_must_be_the_contexts_active_build() {
        let api = FakeApi::new([record("a", "a2", PHASE_ACTIVE)]);
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open(&client, &discovery).unwrap().into_records();
        let records = records.as_ref();
        assert!(
            check_cached_baseline(records, "a", "a2", None)
                .await
                .is_ok()
        );
        let err = check_cached_baseline(records, "a", "p9", Some("prod-eu"))
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("(build a2)"), "{err}");
        assert!(err.contains("Nothing was applied to the cluster."), "{err}");
        assert!(err.contains("kix deploy a --context prod-eu"), "{err}");
        let err = check_cached_baseline(records, "b", "p9", None)
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("has no active deployment record"), "{err}");
    }

    /// Verify that `refuse_name_taken` rejects an Activation name already bound
    /// to a different build hash.
    #[tokio::test]
    async fn a_record_name_held_by_another_build_is_refused() {
        let api = FakeApi::new([record("a", "a2", PHASE_ACTIVE)]);
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open(&client, &discovery)
            .unwrap()
            .into_records()
            .unwrap();
        assert!(refuse_name_taken(&records, "rec-a2", "a2").await.is_ok());
        assert!(refuse_name_taken(&records, "rec-new", "n1").await.is_ok());
        let err = refuse_name_taken(&records, "rec-a2", "n1")
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("on cluster:  a2\n"), "{err}");
        assert!(
            err.contains("This build:                           n1"),
            "{err}"
        );
    }

    /// Verify that `refuse_namespaceless` rejects a namespaced resource with no
    /// `metadata.namespace`.
    #[tokio::test]
    async fn an_object_without_its_namespace_is_refused() {
        let api = FakeApi::new([]);
        let discovery = discovery::discover_resources(&api.client()).await.unwrap();
        let plan = kix::cluster::scheduler::DeployPlan::applying(&[json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": { "name": "c" },
        })]);
        let err = refuse_namespaceless(&discovery, &plan)
            .unwrap_err()
            .to_string();
        assert!(err.contains("ConfigMap"), "{err}");
    }
}

mod run_end_tests {
    use super::*;
    use kix::cluster::scheduler::{DeployPlan, PrunePolicy};
    use kix::cluster::scripted::{ApplyFailure, Behaviour, NodeScript, ScriptedOps};
    use kix::cluster::stream::NullObserver;
    use kix::manifest::keys;
    use serde_json::json;

    fn deployment(name: &str, deps: &[&str]) -> Value {
        let mut annotations = serde_json::Map::new();
        annotations.insert(keys::IDENTITY_HASH.into(), json!(format!("h_{name}")));
        if !deps.is_empty() {
            let deps: Vec<String> = deps.iter().map(|d| format!("h_{d}")).collect();
            annotations.insert(keys::DEPENDS_ON.into(), json!(deps.join(",")));
        }
        json!({
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": { "name": name, "namespace": "default", "annotations": annotations },
        })
    }

    fn deployment_id(name: &str) -> ResourceId {
        ResourceId {
            kind: "Deployment".into(),
            namespace: "default".into(),
            name: name.into(),
        }
    }

    struct Settings {
        config: SchedulerConfig,
        prune: PrunePolicy,
    }

    fn config(on_error: OnErrorPolicy, prune: PrunePolicy) -> Settings {
        Settings {
            config: SchedulerConfig {
                timeout: Duration::from_secs(300),
                on_error,
                cancel: kix::cluster::cancel::CancelToken::new(),
                concurrency: scheduler::CONCURRENCY,
                stall: StallPolicy::off(),
                rerun_failed: true,
                check_unchanged: true,
                names_flags: true,
            },
            prune,
        }
    }

    fn ops_failing_a() -> Arc<ScriptedOps> {
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            deployment_id("a"),
            NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("boom".into())))),
        );
        ops
    }

    async fn run(
        ops: &Arc<ScriptedOps>,
        manifests: &[Value],
        orphans: &[ResourceId],
        old: &[Value],
        settings: &Settings,
    ) -> std::result::Result<DeployResult, scheduler::DeployError> {
        scheduler::run_scripted(
            ops.clone(),
            DeployPlan::applying(manifests),
            orphans,
            old,
            settings.prune,
            &settings.config,
            Arc::new(NullObserver),
        )
        .await
    }

    /// Verify that under `--on-error continue`, a failed node with no cancelled
    /// dependents marks the activation current (Degraded) and exits non-zero.
    #[tokio::test]
    async fn continue_with_a_failed_node_exits_non_zero() {
        let manifests = [deployment("a", &[]), deployment("b", &[])];
        let cfg = config(OnErrorPolicy::Continue, PrunePolicy::WarnOnly);
        let result = run(&ops_failing_a(), &manifests, &[], &[], &cfg).await;
        assert_eq!(result.as_ref().unwrap().failed, 1);
        assert_eq!(
            RunEnd::of(&result),
            RunEnd {
                succeeded: false,
                current: true,
            }
        );
    }

    /// Verify that under `--on-error continue`, a failed node that cancels a
    /// dependent leaves the activation not current and exits non-zero.
    #[tokio::test]
    async fn continue_with_a_cancelled_dependent_is_not_current() {
        let manifests = [deployment("a", &[]), deployment("b", &["a"])];
        let cfg = config(OnErrorPolicy::Continue, PrunePolicy::WarnOnly);
        let result = run(&ops_failing_a(), &manifests, &[], &[], &cfg).await;
        let counts = result.as_ref().unwrap();
        assert_eq!((counts.failed, counts.cancelled), (1, 1));
        assert_eq!(
            RunEnd::of(&result),
            RunEnd {
                succeeded: false,
                current: false,
            }
        );
    }

    /// Verify that a failed prune delete causes the deploy to exit non-zero.
    #[tokio::test]
    async fn a_failed_prune_delete_exits_non_zero() {
        let ops = Arc::new(ScriptedOps::new());
        ops.delete_behaviour(Behaviour::Now(Err("forbidden".into())));
        let cfg = config(OnErrorPolicy::Stop, PrunePolicy::Delete);
        let result = run(
            &ops,
            &[deployment("a", &[])],
            &[deployment_id("old")],
            &[deployment("old", &[])],
            &cfg,
        )
        .await;
        assert_eq!(result.as_ref().unwrap().failed, 1);
        assert!(!RunEnd::of(&result).succeeded);
    }

    /// Verify that a finalization failure marks the run as neither succeeded nor
    /// current.
    #[tokio::test]
    async fn a_failed_finalize_is_neither_succeeded_nor_current() {
        let ops = Arc::new(ScriptedOps::new());
        ops.finalize_behaviour(Behaviour::Now(Err("conflict".into())));
        let cfg = config(OnErrorPolicy::Stop, PrunePolicy::WarnOnly);
        let result = run(&ops, &[deployment("a", &[])], &[], &[], &cfg).await;
        assert!(
            matches!(result, Err(scheduler::DeployError::FinalizeFailed { .. })),
            "{result:?}"
        );
        assert_eq!(
            RunEnd::of(&result),
            RunEnd {
                succeeded: false,
                current: false,
            }
        );
    }

    /// Verify that a run with cancelled nodes whose abort also fails is neither
    /// succeeded nor current.
    #[tokio::test]
    async fn a_failed_abort_is_neither_succeeded_nor_current() {
        let ops = ops_failing_a();
        ops.abort_behaviour(Behaviour::Now(Err("conflict".into())));
        let manifests = [deployment("a", &[]), deployment("b", &["a"])];
        let cfg = config(OnErrorPolicy::Continue, PrunePolicy::WarnOnly);
        let result = run(&ops, &manifests, &[], &[], &cfg).await;
        assert_eq!(
            RunEnd::of(&result),
            RunEnd {
                succeeded: false,
                current: false,
            }
        );
    }

    #[tokio::test]
    async fn a_clean_run_succeeds() {
        let manifests = [deployment("a", &[]), deployment("b", &["a"])];
        let cfg = config(OnErrorPolicy::Continue, PrunePolicy::WarnOnly);
        let result = run(&Arc::new(ScriptedOps::new()), &manifests, &[], &[], &cfg).await;
        assert_eq!(
            RunEnd::of(&result),
            RunEnd {
                succeeded: true,
                current: true,
            }
        );
    }

    #[test]
    fn the_summary_line_names_a_failed_run() {
        let counts = DeployResult {
            created: 2,
            unchanged: 348,
            failed: 2,
            cancelled: 3,
            ..DeployResult::default()
        };
        let line = summary_line(&counts, false, false);
        assert!(line.starts_with("Deploy failed: "), "{line}");
        assert!(line.contains("2 failed"), "{line}");
        let stopped = summary_line(&DeployResult::default(), false, false);
        assert!(stopped.starts_with("Deploy stopped: "), "{stopped}");
        let ok = summary_line(&DeployResult::default(), true, true);
        assert!(ok.starts_with("Dry run complete: "), "{ok}");
    }

    /// A failed deploy closes with the failed resources, the records, and a
    /// next step that does not offer a rollback.
    #[test]
    fn a_failed_deploy_says_what_is_live_and_what_to_do() {
        let counts = DeployResult {
            created: 3,
            configured: 12,
            failed: 1,
            cancelled: 4,
            failures: vec![kix::cluster::stream::NodeFailure {
                node: NodeId::Resource(ResourceId {
                    kind: "Deployment".into(),
                    namespace: "app".into(),
                    name: "api".into(),
                }),
                message: "ImagePullBackOff\nsecond line".into(),
            }],
            ..DeployResult::default()
        };
        let closing = |previous, interrupted| Closing {
            cluster: "prod",
            record: Some("prod-8a1f3c20"),
            previous,
            interrupted,
            current: false,
            on_error_continue: false,
        };
        let text = super::observer::closing(
            &counts,
            &closing(Previous::Active("prod-4be1c09a".into()), None),
        );
        assert!(text.starts_with("Deploy of 'prod' failed: "), "{text}");
        assert!(
            text.contains("    - Deployment/api@app: ImagePullBackOff\n"),
            "{text}"
        );
        assert!(
            text.contains("Deployment record prod-8a1f3c20 is marked Failed, and prod-4be1c09a remains the Active deployment record."),
            "{text}"
        );
        assert!(!text.contains("rollback"), "{text}");
        assert!(text.contains(", 4 not started"), "{text}");
        assert!(
            text.contains("1 failed (during apply or after being applied), and 4 were never sent to the cluster."),
            "{text}"
        );
        let first = super::observer::closing(&counts, &closing(Previous::FirstDeploy, None));
        assert!(first.contains("no Active deployment record yet"), "{first}");
        let stopped =
            super::observer::closing(&counts, &closing(Previous::Unknown, Some("interrupted")));
        assert!(
            stopped.starts_with("Deploy of 'prod' stopped (interrupted): "),
            "{stopped}"
        );
        assert!(stopped.contains("4 object(s) did not finish"), "{stopped}");
    }
}

mod operator_tests {
    use super::*;
    use crate::cli::{Cli, Command};
    use clap::Parser;
    use kix::cluster::scheduler::PrunePolicy;

    /// Verify that `operator_flags` always forces `PrunePolicy::Delete`.
    #[test]
    fn an_operator_deploy_is_checked_as_one_that_prunes() {
        for extra in [&[][..], &["--prune-mode", "no"][..]] {
            let argv = [&["kix", "deploy", "x", "--operator"][..], extra].concat();
            let Command::Deploy(args) = Cli::try_parse_from(argv).expect("args parse").command
            else {
                unreachable!()
            };
            let flags = operator_flags(flags_of(&args.plan));
            assert_eq!(flags.prune_policy(), PrunePolicy::Delete, "{extra:?}");
        }
    }

    /// Verify that `--operator` and `--bundle` cannot be combined because the
    /// operator reads builds from the Nix store.
    #[test]
    fn an_operator_deploy_does_not_take_a_bundle() {
        let parsed = Cli::try_parse_from([
            "kix",
            "deploy",
            "x",
            "--operator",
            "--bundle",
            "x.kixbundle",
        ]);
        assert!(parsed.is_err());
    }
}
