//! Import markers that two Kix clusters on one Kubernetes cluster both
//! applied with an earlier Kix, and that this Kix no longer applies. Each
//! Kix cluster that applied a marker must end with its `Apply` entry gone
//! or with a record of its own naming the marker.

use super::*;

const MARKER: &str = "platform-dns";

fn marker() -> Value {
    import_marker("kube-system", MARKER, "v1", "Service", "kube-dns")
}

/// Return the build an earlier Kix deployed for Kix cluster `cluster`.
fn old_build(cluster: &str) -> StoreGraph {
    build_of(
        cluster,
        &[marker(), config_map(&format!("in-{cluster}"), "1")],
    )
}

/// Return this Kix's build of Kix cluster `cluster` with record `record`.
fn new_build(cluster: &str, record: &str) -> StoreGraph {
    release_of(
        cluster,
        record,
        &[marker(), config_map(&format!("in-{cluster}"), "1")],
    )
}

/// Put on a fake API server the Kix clusters `clusters`, each deployed by
/// an earlier Kix: a current record `<cluster>-cur` whose format 1
/// revisions name the marker among their objects, and its ConfigMap. The
/// marker carries one `Apply` entry for each cluster.
async fn deployed_by_an_earlier_kix(clusters: &[&str]) -> FakeApi {
    deployed_by_earlier_kixes(clusters, &[]).await
}

/// Put on a fake API server the Kix clusters `clusters` as
/// [`deployed_by_an_earlier_kix`] does, and the Kix clusters `older` as a
/// Kix before revisions left them: a current record with no map, and the
/// marker applied under the shared manager `kix` with a note that names
/// the record.
async fn deployed_by_earlier_kixes(clusters: &[&str], older: &[&str]) -> FakeApi {
    let api = FakeApi::new([]);
    let store = Revisions::new(&api.client());
    let mut entries = Vec::new();
    let mut noted = Vec::new();
    for cluster in older {
        api.insert(json!({
            "apiVersion": keys::API_VERSION,
            "kind": RECORD_KIND,
            "metadata": {
                "name": format!("{cluster}-cur"),
                "labels": {
                    (keys::CLUSTER_LABEL): cluster,
                    "app.kubernetes.io/managed-by": "kix",
                },
                "annotations": { (keys::IDENTITY_HASH): format!("rec-{cluster}") },
            },
            "status": { "phase": PHASE_ACTIVE, "deployedAt": "2026-11-01T00:00:00Z" },
        }));
        noted.push(format!("rec-{cluster}"));
        entries.push(json!({
            "manager": crate::cluster::field_manager::LEGACY,
            "operation": "Apply",
            "apiVersion": keys::API_VERSION,
            "fieldsV1": {
                "f:metadata": { "f:labels": { "f:app.kubernetes.io/managed-by": {} } },
                "f:spec": { "f:instanceName": {}, "f:mode": {} },
            },
        }));
    }
    for cluster in clusters {
        let set = in_format_one(&RevisionSet::of(cluster, &old_build(cluster)));
        let current = format!("{cluster}-cur");
        api.insert(json!({
            "apiVersion": keys::API_VERSION,
            "kind": RECORD_KIND,
            "metadata": {
                "name": current,
                "labels": {
                    (keys::CLUSTER_LABEL): cluster,
                    "app.kubernetes.io/managed-by": "kix",
                },
                "annotations": { (keys::IDENTITY_HASH): format!("rec-{cluster}") },
            },
            "status": {
                "phase": PHASE_ACTIVE,
                "revisions": RevisionMap::of(&set).to_value(),
            },
        }));
        api.insert(json!({
            "apiVersion": keys::API_VERSION,
            "kind": crate::cluster::head::KIND,
            "metadata": { "name": cluster },
            "status": { "current": current, "generation": 1 },
        }));
        for revision in set.all() {
            store.create(revision).await.unwrap();
        }
        let mut conf = manifests(&old_build(cluster))
            .into_iter()
            .find(|m| m["kind"] == "ConfigMap")
            .unwrap();
        conf = without_graph_notes(conf);
        conf["metadata"]["managedFields"][0]["manager"] = json!(format!("kix/{cluster}"));
        api.insert(conf);
        entries.push(json!({
            "manager": format!("kix/{cluster}"),
            "operation": "Apply",
            "apiVersion": keys::API_VERSION,
            "fieldsV1": {
                "f:metadata": { "f:labels": { "f:app.kubernetes.io/managed-by": {} } },
                "f:spec": { "f:instanceName": {}, "f:mode": {} },
            },
        }));
    }
    let mut live = manifests(&old_build(clusters[0]))
        .into_iter()
        .find(crate::manifest::lifecycle::is_marker)
        .unwrap();
    live["metadata"]["managedFields"] = json!(entries);
    if !noted.is_empty() {
        live["metadata"]["annotations"][keys::ACTIVATIONS] = json!(noted.join(","));
    }
    api.insert(live);
    api.track_owners();
    api
}

/// Return the Kix clusters with an `Apply` entry on the marker, sorted, or
/// `None` when the marker is gone.
fn appliers(api: &FakeApi) -> Option<Vec<String>> {
    let obj = api.object(crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND, MARKER)?;
    let mut out: Vec<String> = obj["metadata"]["managedFields"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|e| e["operation"] == "Apply")
        .filter_map(|e| e["manager"].as_str()?.strip_prefix("kix/"))
        .map(str::to_string)
        .collect();
    out.sort();
    Some(out)
}

/// Return whether a record Kix cluster `cluster` needs names the marker,
/// its kept-orphans revision included.
async fn named_by(api: &FakeApi, cluster: &str) -> bool {
    let client = api.client();
    let opened = Records::open(
        &client,
        &discovery::discover_resources(&client).await.unwrap(),
    )
    .unwrap();
    let tenancy = crate::cluster::tenancy::read(&opened, cluster)
        .await
        .unwrap();
    let obj: DynamicObject = serde_json::from_value(
        api.object(crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND, MARKER)
            .unwrap(),
    )
    .unwrap();
    tenancy.named_by_own(&obj)
}

/// Assert that every Kix cluster with an `Apply` entry on the marker has a
/// record that names it.
async fn assert_no_leak(api: &FakeApi, when: &str) {
    for cluster in appliers(api).unwrap_or_default() {
        assert!(
            named_by(api, &cluster).await,
            "{when}: Kix cluster {cluster} applied the marker and no record of it names it"
        );
    }
}

async fn deploy(api: &FakeApi, cluster: &str, record: &str) {
    let checked = cli_plan_of(api, cluster, &new_build(cluster, record)).await;
    let result = cli_run_of(api, cluster, checked).await.unwrap();
    assert_eq!(result.failed, 0, "{cluster}: {result:?}");
}

/// Two Kix clusters deploy this Kix in turn, with nothing stopped. After
/// each deploy, each Kix cluster that applied the marker still names it.
/// A deploy of the last holder with `--prune` deletes it.
#[tokio::test]
async fn a_marker_two_clusters_applied_is_handed_over_and_pruned() {
    let api = deployed_by_an_earlier_kix(&["a", "b"]).await;
    assert_no_leak(&api, "before").await;

    let plan_a = cli_plan_of(&api, "a", &new_build("a", "a-v1")).await;
    assert_eq!(plan_a.shared_orphans().len(), 1);
    deploy(&api, "a", "a-v1").await;
    assert_no_leak(&api, "after a").await;

    deploy(&api, "b", "b-v1").await;
    assert_no_leak(&api, "after b").await;
    assert!(
        appliers(&api).is_some(),
        "a deploy without --prune keeps it"
    );

    let pruned = cli_plan_with(&api, "b", &new_build("b", "b-v2"), &["--prune"]).await;
    cli_run_of(&api, "b", pruned).await.unwrap();
    assert_no_leak(&api, "after b --prune").await;
    assert_eq!(appliers(&api), None, "{:?}", appliers(&api));
}

/// Plan this Kix's build of Kix cluster `cluster` as `kix deploy` does when
/// the deploy lock may still name a run that died: a dead run of another
/// build has its record marked `Failed`, and one of the same build is
/// continued.
async fn plan_settling(
    api: &FakeApi,
    cluster: &str,
    graph: &StoreGraph,
    flags: &[&str],
) -> crate::plan::CheckedPlan {
    let client = api.client();
    let baseline = current_baseline_of(&client, cluster).await;
    let settle = crate::plan::planner::Settle {
        command: "kix deploy",
        purpose: crate::cluster::head::Purpose::Deploy,
    };
    let mut checked = crate::plan::Planner::new(crate::plan::fixtures::flags(flags), &|_| {})
        .settling(settle)
        .plan(graph, cluster, &baseline, Some(&client))
        .await
        .unwrap();
    let target = crate::plan::Target::connect(client, crate::build_source::SopsSources::Local)
        .await
        .unwrap();
    checked.ask_takes_back(&target).await;
    checked
}

/// Run `checked` for Kix cluster `cluster` as `kix deploy` does, and let
/// only the first `cut` requests of the run reach the cluster, as when the
/// process is killed. Return whether the run sent more requests than that.
async fn run_killed(
    api: &FakeApi,
    cluster: &str,
    checked: crate::plan::CheckedPlan,
    cut: usize,
) -> bool {
    let before = api.requests().len();
    api.cut_after(cut);
    let client = api.client();
    let taken = crate::cluster::head::take(
        &client,
        crate::cluster::head::Request {
            cluster: cluster.into(),
            holder: crate::cluster::head::Holder::cli("kix deploy"),
            purpose: crate::cluster::head::Purpose::Deploy,
            activation: checked.activation_name().map(str::to_string),
            expect: None,
        },
        crate::cluster::head::system_clock(),
        &|_| {},
    )
    .await;
    if let Ok(lock) = taken {
        let lock = Arc::new(lock);
        if let Ok(target) =
            crate::plan::Target::connect(client, crate::build_source::SopsSources::Local).await
        {
            let _ = checked
                .run(
                    target,
                    lock.clone(),
                    None,
                    test_config(),
                    Arc::new(crate::cluster::stream::NullObserver),
                )
                .await;
        }
    }
    let reached = api.requests().len() - before;
    api.restore();
    // A killed process never gives the lock up. Its lease runs out.
    if api.object(crate::cluster::head::KIND, cluster).unwrap()["status"]["lock"].is_object() {
        let renewed = (chrono::Utc::now() - chrono::Duration::hours(1))
            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        api.patch_object(crate::cluster::head::KIND, cluster, |o| {
            o["status"]["lock"]["renewed"] = json!(renewed);
        });
    }
    reached >= cut
}

/// Deploy this Kix's build of `cluster` with `flags`, after a run that may
/// have died, and check that nothing fails.
async fn deploy_after(api: &FakeApi, cluster: &str, record: &str, flags: &[&str]) {
    let checked = plan_settling(api, cluster, &new_build(cluster, record), flags).await;
    let result = cli_run_of(api, cluster, checked).await.unwrap();
    assert_eq!(result.failed, 0, "{cluster}: {result:?}");
}

/// Kill the deploy of `killed`, the first of `order` to deploy this Kix,
/// after each number of requests in turn, then deploy every Kix cluster of
/// `order` again, and then the last one with `--prune`. After every step,
/// each Kix cluster with an entry on the marker has a record naming it, and
/// at the end the marker is gone.
async fn kill_at_every_request(order: [&str; 2], killed: &str) {
    for cut in 0.. {
        let api = deployed_by_an_earlier_kix(&["a", "b"]).await;
        for cluster in order {
            if cluster == killed {
                break;
            }
            deploy(&api, cluster, &format!("{cluster}-v1")).await;
        }
        let checked = cli_plan_of(&api, killed, &new_build(killed, &format!("{killed}-v1"))).await;
        let more = run_killed(&api, killed, checked, cut).await;
        let when = format!("killed after {cut} requests");
        assert_no_leak(&api, &when).await;
        for cluster in order {
            deploy_after(&api, cluster, &format!("{cluster}-v2"), &[]).await;
            assert_no_leak(&api, &format!("{when}, then {cluster}")).await;
        }
        let last = order[1];
        deploy_after(&api, last, &format!("{last}-v3"), &["--prune"]).await;
        assert_no_leak(&api, &format!("{when}, then {last} --prune")).await;
        assert_eq!(appliers(&api), None, "{when}");
        if !more {
            break;
        }
    }
}

/// The first deploy of `a` by this Kix dies after each number of requests
/// in turn, `b` deploying after it.
#[tokio::test(start_paused = true)]
async fn a_kill_of_the_first_holder_at_any_request_leaks_nothing() {
    kill_at_every_request(["a", "b"], "a").await;
}

/// The deploy of `b`, after `a` handed the marker over, dies after each
/// number of requests in turn.
#[tokio::test(start_paused = true)]
async fn a_kill_of_the_last_holder_at_any_request_leaks_nothing() {
    kill_at_every_request(["a", "b"], "b").await;
}

fn marker_path() -> String {
    format!(
        "/apis/{}/namespaces/kube-system/packageinstances/{MARKER}",
        keys::API_VERSION
    )
}

/// Return the `Apply` entry Kix cluster `cluster` holds on the marker.
fn entry_of(cluster: &str) -> Value {
    json!({
        "manager": format!("kix/{cluster}"),
        "operation": "Apply",
        "apiVersion": keys::API_VERSION,
        "fieldsV1": {
            "f:metadata": { "f:labels": { "f:app.kubernetes.io/managed-by": {} } },
            "f:spec": { "f:instanceName": {}, "f:mode": {} },
        },
    })
}

/// Put Kix cluster `cluster`'s `Apply` entry back on the marker.
fn add_entry(api: &FakeApi, cluster: &str) {
    api.patch_object(
        crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND,
        MARKER,
        |o| {
            o["metadata"]["managedFields"]
                .as_array_mut()
                .unwrap()
                .push(entry_of(cluster));
        },
    );
}

fn work(checked: &crate::plan::CheckedPlan) -> crate::plan::Work {
    checked.work(&crate::plan::LastRuns::Read { failed: Vec::new() })
}

/// When Kubernetes accepts the release of `a`'s fields but keeps `a`'s
/// entry, `a`'s record keeps naming the marker as a kept orphan. The next
/// deploy of the same build has that release left to do, so it runs, and
/// hands the marker over.
#[tokio::test]
async fn a_release_that_leaves_the_entry_keeps_the_marker_named() {
    let api = deployed_by_an_earlier_kix(&["a", "b"]).await;
    // The run sends the marker one apply, the release.
    api.on_apply(MARKER, |o| {
        o["metadata"]["managedFields"]
            .as_array_mut()
            .unwrap()
            .push(entry_of("a"));
    });
    deploy(&api, "a", "a-v1").await;
    assert_eq!(appliers(&api), Some(vec!["a".into(), "b".into()]));
    assert_no_leak(&api, "after a").await;

    let again = cli_plan_of(&api, "a", &new_build("a", "a-v1")).await;
    assert_ne!(work(&again), crate::plan::Work::Nothing);
    cli_run_of(&api, "a", again).await.unwrap();
    assert_eq!(appliers(&api), Some(vec!["b".into()]));
    assert!(!named_by(&api, "a").await);
    assert_no_leak(&api, "after a again").await;
}

/// A release that fails leaves the marker in `a`'s kept-orphans list. A
/// deploy of the same build with nothing else to do still runs, because
/// the release is left, and gives the fields up.
#[tokio::test]
async fn a_failed_release_is_done_by_the_next_deploy_of_the_same_build() {
    let api = deployed_by_an_earlier_kix(&["a", "b"]).await;
    let checked = cli_plan_of(&api, "a", &new_build("a", "a-v1")).await;
    api.fail_next(&marker_path(), 1, 500);
    cli_run_of(&api, "a", checked).await.unwrap();
    assert_eq!(appliers(&api), Some(vec!["a".into(), "b".into()]));
    assert!(named_by(&api, "a").await);

    let again = cli_plan_of(&api, "a", &new_build("a", "a-v1")).await;
    assert!(writes(&again).is_empty(), "{:?}", writes(&again));
    assert_ne!(work(&again), crate::plan::Work::Nothing);
    cli_run_of(&api, "a", again).await.unwrap();
    assert_eq!(appliers(&api), Some(vec!["b".into()]));
    assert_no_leak(&api, "after a again").await;
}

/// The state a real cluster reached: `a` handed the marker over and its
/// record no longer names it, but `a`'s entry is still on the marker. `b`
/// does not defer to that entry, since no record of `a` names the marker:
/// `b` keeps the marker in its own kept-orphans list, and `b --prune`
/// deletes it.
#[tokio::test]
async fn an_entry_no_record_names_does_not_keep_the_marker() {
    let api = deployed_by_an_earlier_kix(&["a", "b"]).await;
    deploy(&api, "a", "a-v1").await;
    add_entry(&api, "a");
    assert!(!named_by(&api, "a").await);

    let plan_b = cli_plan_of(&api, "b", &new_build("b", "b-v1")).await;
    assert!(
        plan_b.shared_orphans().is_empty(),
        "{:?}",
        plan_b.shared_orphans()
    );
    deploy(&api, "b", "b-v1").await;
    assert!(named_by(&api, "b").await);

    deploy_after(&api, "b", "b-v2", &["--prune"]).await;
    assert_eq!(appliers(&api), None);
}

/// A third Kix cluster `c` still deploys the marker from its format 1
/// record. `a` and `b` each hand it over in turn, with and without
/// `--prune`, and the marker stays, named by `c`.
#[tokio::test]
async fn a_marker_a_third_cluster_still_deploys_survives() {
    let api = deployed_by_an_earlier_kix(&["a", "b", "c"]).await;
    deploy(&api, "a", "a-v1").await;
    assert_no_leak(&api, "after a").await;
    deploy_after(&api, "b", "b-v1", &["--prune"]).await;
    assert_no_leak(&api, "after b --prune").await;
    deploy_after(&api, "a", "a-v2", &["--prune"]).await;
    assert_eq!(appliers(&api), Some(vec!["c".into()]));
    assert!(named_by(&api, "c").await);
    assert!(!named_by(&api, "a").await);
    assert!(!named_by(&api, "b").await);
}

/// A third Kix cluster `c` still deploys the marker with a Kix from before
/// revisions, which named it in the marker's note. `a` and `b` hand it
/// over, with `--prune`, and the marker stays with `c`'s entry and note.
#[tokio::test]
async fn a_marker_an_older_kix_still_deploys_survives() {
    let api = deployed_by_earlier_kixes(&["a", "b"], &["c"]).await;
    deploy(&api, "a", "a-v1").await;
    assert_no_leak(&api, "after a").await;
    deploy_after(&api, "b", "b-v1", &["--prune"]).await;
    assert_no_leak(&api, "after b --prune").await;
    deploy_after(&api, "a", "a-v2", &["--prune"]).await;
    let marker = api
        .object(crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND, MARKER)
        .expect("the marker stays");
    assert_eq!(appliers(&api), Some(Vec::<String>::new()));
    assert_eq!(
        marker["metadata"]["annotations"][keys::ACTIVATIONS],
        json!("rec-c")
    );
    assert!(!named_by(&api, "a").await);
    assert!(!named_by(&api, "b").await);
}

/// Return the kept-orphans revision the current record of Kix cluster
/// `cluster` names, or `None` when its revision map names none.
async fn kept_orphans_of(api: &FakeApi, cluster: &str) -> Option<Revision> {
    let head = api.object(crate::cluster::head::KIND, cluster).unwrap();
    let current = head["status"]["current"].as_str().unwrap().to_string();
    let record = api.object(RECORD_KIND, &current).unwrap();
    let map = RevisionMap::read(&record["status"]["revisions"]).unwrap();
    let name = map.kept_orphans?;
    Revisions::new(&api.client()).get(&name).await.unwrap()
}

/// Put on a fake API server Kix cluster `a` as an earlier Kix left it
/// after deploying `graph`: `graph`'s record as the current one, with
/// format 1 revisions that name the marker among their objects and hold
/// the applied hash of each other object, the ConfigMap, and the marker
/// with `a`'s `Apply` entry.
async fn deployed_by_an_earlier_kix_as(graph: &StoreGraph) -> FakeApi {
    let set = in_format_one(&RevisionSet::of("a", graph));
    let mut record = manifests(graph)
        .into_iter()
        .find(crate::manifest::lifecycle::is_record)
        .unwrap();
    record["metadata"]["labels"]["app.kubernetes.io/managed-by"] = json!("kix");
    record["status"] = json!({
        "phase": PHASE_ACTIVE,
        "revisions": RevisionMap::of(&set).to_value(),
    });
    let current = record["metadata"]["name"].as_str().unwrap().to_string();
    let head = json!({
        "apiVersion": keys::API_VERSION,
        "kind": crate::cluster::head::KIND,
        "metadata": { "name": "a" },
        "status": { "current": current, "generation": 1 },
    });
    let mut live = vec![record, head];
    for mut m in manifests(graph) {
        if crate::manifest::lifecycle::is_record(&m) {
            continue;
        }
        if crate::manifest::lifecycle::is_marker(&m) {
            m["metadata"]["managedFields"] = json!([entry_of("a")]);
        } else {
            m = without_graph_notes(m);
        }
        live.push(m);
    }
    let api = FakeApi::new(live.clone());
    let store = Revisions::new(&api.client());
    let manager = crate::cluster::field_manager::FieldManager::of("a");
    for revision in set.all() {
        store.create(revision).await.unwrap();
        let applied: std::collections::BTreeMap<String, String> = revision
            .spec
            .objects
            .iter()
            .filter_map(|o| {
                let m = live
                    .iter()
                    .find(|m| ResourceId::from_value(m) == o.resource_id())?;
                if crate::manifest::lifecycle::is_marker(m) {
                    return None;
                }
                let obj: DynamicObject = serde_json::from_value(m.clone()).unwrap();
                let hash = crate::cluster::fieldsv1::applied_content_hash(&obj, &manager)?;
                Some((o.hash.clone(), hash))
            })
            .collect();
        if !applied.is_empty() {
            store.write_applied(&revision.name, &applied).await.unwrap();
        }
    }
    api.track_owners();
    api
}

/// Plan `graph` for Kix cluster `a` with `flags`, as `kix deploy` does when
/// this machine holds the current record's build, which is `graph`.
async fn plan_same_build(
    api: &FakeApi,
    graph: &StoreGraph,
    flags: &[&str],
) -> crate::plan::CheckedPlan {
    let client = api.client();
    let baseline = crate::plan::baseline::Baseline {
        active_manifests: manifests(graph),
        source: crate::plan::baseline::ActiveSource::Build(Box::new(graph.clone())),
        ..current_baseline_of(&client, "a").await
    };
    let mut checked = crate::plan::Planner::new(crate::plan::fixtures::flags(flags), &|_| {})
        .plan(graph, "a", &baseline, Some(&client))
        .await
        .unwrap();
    let target = crate::plan::Target::connect(client, crate::build_source::SopsSources::Local)
        .await
        .unwrap();
    checked.ask_takes_back(&target).await;
    checked
}

/// The state a real cluster reached: one Kix cluster an earlier Kix
/// deployed, whose format 1 revisions name the marker among their objects.
/// This Kix deploys the same build. The plan writes nothing, and the run
/// only converts the revisions and rewrites metadata. The run still
/// finalizes, so the record's kept-orphans revision names the marker, a
/// second deploy keeps it named, and a deploy with `--prune` deletes it.
#[tokio::test]
async fn a_deploy_of_the_same_build_keeps_the_marker_named() {
    let graph = new_build("a", "a-v1");
    let api = deployed_by_an_earlier_kix_as(&graph).await;
    assert_eq!(kept_orphans_of(&api, "a").await, None);
    assert_no_leak(&api, "before").await;

    for when in ["first deploy", "second deploy"] {
        let checked = plan_same_build(&api, &graph, &[]).await;
        assert!(
            written(checked.plan()).is_empty(),
            "{when}: {:?}",
            written(checked.plan())
        );
        assert_eq!(names(checked.orphans()), [MARKER], "{when}");
        let result = cli_run_of(&api, "a", checked).await.unwrap();
        assert_eq!(
            (
                result.created,
                result.configured,
                result.pruned,
                result.kept,
                result.failed
            ),
            (0, 0, 0, 0, 0),
            "{when}: {result:?}"
        );
        let kept = kept_orphans_of(&api, "a")
            .await
            .unwrap_or_else(|| panic!("{when}: no kept-orphans revision"));
        assert!(
            kept.spec.objects.iter().any(|o| o.name == MARKER),
            "{when}: {kept:?}"
        );
        assert_eq!(appliers(&api), Some(vec!["a".into()]), "{when}");
        assert_no_leak(&api, when).await;
    }

    let pruned = plan_same_build(&api, &graph, &["--prune"]).await;
    assert_eq!(names(pruned.orphans()), [MARKER]);
    cli_run_of(&api, "a", pruned).await.unwrap();
    assert_eq!(appliers(&api), None);
}
