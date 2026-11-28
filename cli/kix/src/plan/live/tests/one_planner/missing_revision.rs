//! A revision the current record names that is missing from the cluster,
//! or that Kix cannot read. A plan reads it from a build that names it, a
//! deploy creates the revisions of its own build, and `kix gc --full-scan`
//! rebuilds a lost kept-orphans list.

use super::*;

/// Plan `graph` for Kix cluster `a` as `kix deploy` does, and return the
/// refusal instead of panicking on it.
async fn try_plan(
    api: &FakeApi,
    graph: &StoreGraph,
    flags: &[&str],
) -> Result<crate::plan::CheckedPlan, crate::plan::PlanError> {
    let client = api.client();
    let baseline = current_baseline_of(&client, "a").await;
    let mut checked = crate::plan::Planner::new(crate::plan::fixtures::flags(flags), &|_| {})
        .plan(graph, "a", &baseline, Some(&client))
        .await?;
    let target = crate::plan::Target::connect(client, crate::build_source::SopsSources::Local)
        .await
        .unwrap();
    checked.ask_takes_back(&target).await;
    Ok(checked)
}

/// Return the revision map of the record Kix cluster `a`'s head calls
/// current.
fn current_map(api: &FakeApi) -> RevisionMap {
    let head = api.object(crate::cluster::head::KIND, "a").unwrap();
    let current = head["status"]["current"].as_str().unwrap().to_string();
    let record = api.object(RECORD_KIND, &current).unwrap();
    RevisionMap::read(&record["status"]["revisions"]).unwrap()
}

fn v1() -> StoreGraph {
    release("a-v1", &[config_map("conf", "1"), config_map("old", "1")])
}

/// Deploy [`v1`] to a fake API server and return it with the name of the
/// revision that names its objects.
async fn deployed() -> (FakeApi, String) {
    let api = FakeApi::new([]);
    api.track_owners();
    let first = cli_deploy(&api, &v1()).await.unwrap();
    assert_eq!(first.failed, 0, "{first:?}");
    let map = current_map(&api);
    assert!(map.instances.is_empty(), "{map:?}");
    (api, map.cluster_level)
}

async fn read(api: &FakeApi, name: &str) -> Option<Revision> {
    Revisions::new(&api.client()).get(name).await.unwrap()
}

/// A deploy of the current record's build recreates a missing revision.
/// The plan cannot know what was applied, so it writes each object again,
/// and the plan after the run writes nothing.
#[tokio::test]
async fn a_deploy_of_the_same_build_recreates_a_missing_revision() {
    let (api, name) = deployed().await;
    Revisions::new(&api.client()).delete(&name).await.unwrap();

    let checked = try_plan(&api, &v1(), &[]).await.unwrap();
    assert_eq!(writes(&checked), ["conf", "old"]);
    let result = cli_run(&api, checked).await.unwrap();
    assert_eq!(result.failed, 0, "{result:?}");

    let rebuilt = read(&api, &name).await.expect("the deploy recreates it");
    assert_eq!(
        rebuilt.applied.len(),
        rebuilt.spec.objects.len(),
        "{rebuilt:?}"
    );
    assert_eq!(current_map(&api).cluster_level, name);
    assert_eq!(writes(&cli_plan(&api, &v1()).await), Vec::<String>::new());
}

/// A revision whose `spec` someone changed no longer matches its name. A
/// deploy whose build names it replaces it with what the name stands for.
#[tokio::test]
async fn a_deploy_of_the_same_build_replaces_an_unreadable_revision() {
    let (api, name) = deployed().await;
    api.patch_object(crate::cluster::revision::KIND, &name, |o| {
        o["spec"]["objects"] = json!([]);
    });
    assert!(Revisions::new(&api.client()).get(&name).await.is_err());

    let checked = try_plan(&api, &v1(), &[]).await.unwrap();
    assert_eq!(writes(&checked), ["conf", "old"]);
    let result = cli_run(&api, checked).await.unwrap();
    assert_eq!(result.failed, 0, "{result:?}");

    let rebuilt = read(&api, &name).await.expect("readable again");
    assert!(rebuilt.spec.objects.iter().any(|o| o.name == "old"));
    assert_eq!(writes(&cli_plan(&api, &v1()).await), Vec::<String>::new());
}

/// A deploy of a build whose revisions differ cannot know what the missing
/// revision named, so it refuses and deletes nothing, even with `--prune`.
/// The message names the record whose build to deploy. Deploying that
/// build recreates the revision, and the changed build then deploys and
/// prunes what it dropped.
#[tokio::test]
async fn a_deploy_of_other_revisions_refuses_until_the_records_build_is_deployed() {
    let (api, name) = deployed().await;
    Revisions::new(&api.client()).delete(&name).await.unwrap();
    let v2 = release("a-v2", &[config_map("conf", "2")]);
    let record = api.object(crate::cluster::head::KIND, "a").unwrap()["status"]["current"]
        .as_str()
        .unwrap()
        .to_string();

    let before = api.requests().len();
    let Err(err) = try_plan(&api, &v2, &["--prune"]).await else {
        panic!("a plan that cannot tell what the revision named");
    };
    let text = err.to_string();
    assert!(
        text.contains(&name) && text.contains(&format!("commit `{record}` was built from")),
        "{text}"
    );
    assert!(text.contains("run `kix deploy a`"), "{text}");
    assert!(
        api.requests()[before..]
            .iter()
            .all(|r| !r.starts_with("DELETE")),
        "{:?}",
        &api.requests()[before..]
    );
    assert!(api.object("ConfigMap", "old").is_some());

    let again = try_plan(&api, &v1(), &[]).await.unwrap();
    cli_run(&api, again).await.unwrap();
    assert!(read(&api, &name).await.is_some());

    let pruned = try_plan(&api, &v2, &["--prune"]).await.unwrap();
    assert_eq!(names(pruned.orphans()), ["old"]);
    let result = cli_run(&api, pruned).await.unwrap();
    assert_eq!(result.failed, 0, "{result:?}");
    assert!(api.object("ConfigMap", "old").is_none());
    assert_eq!(
        api.object("ConfigMap", "conf").unwrap()["data"]["k"],
        json!("2")
    );
}

/// The operator reads a lost revision from the record's build too. A
/// repair, which writes no record, creates the revision, and a later repair
/// finds it and records what it applied.
#[tokio::test]
async fn an_operator_repair_recreates_a_lost_revision() {
    let (api, name) = deployed().await;
    Revisions::new(&api.client()).delete(&name).await.unwrap();
    let repair = operator_plan(&api, &v1()).await;
    let result = operator_repair(&api, repair).await;
    assert_eq!(result.failed, 0, "{result:?}");
    let rebuilt = read(&api, &name).await.expect("the repair recreates it");
    // The operator applies every object but the Activation record.
    assert_eq!(rebuilt.applied.len(), 2, "{rebuilt:?}");
    assert_eq!(operator_plan(&api, &v1()).await.applies(), 0);
}

/// Every revision of the Kix cluster is deleted, the kept-orphans list
/// among them. Each refusal names a step that works in that state: the
/// deploy names `kix gc --full-scan`, which rebuilds the list while it reads
/// the built revisions from the current build, and the deploy after it
/// recreates the rest and can prune the kept orphan.
#[tokio::test]
async fn every_revision_deleted_recovers_by_the_printed_steps() {
    let (api, _) = deployed().await;
    let v2 = release("a-v2", &[config_map("conf", "1")]);
    let result = cli_deploy(&api, &v2).await.unwrap();
    assert_eq!(result.failed, 0, "{result:?}");
    assert!(current_map(&api).kept_orphans.is_some());
    let client = api.client();
    let store = Revisions::new(&client);
    for name in api.names(crate::cluster::revision::KIND) {
        store.delete(&name).await.unwrap();
    }

    let Err(err) = try_plan(&api, &v2, &[]).await else {
        panic!("a plan with no kept-orphans list");
    };
    let text = err.to_string();
    assert!(text.contains("kix gc --full-scan a"), "{text}");

    // What `kix gc --full-scan a` does, comparing with the current build.
    let discovery = discovery::discover_resources(&client).await.unwrap();
    let opened = Records::open(&client, &discovery).unwrap();
    let sweep = crate::cluster::inventory::sweep_managed_with(
        &client,
        &discovery,
        &opened,
        crate::cluster::inventory::SweepScope::Cluster("a"),
        &[&v2],
    )
    .await
    .unwrap();
    assert!(
        sweep.tenancy.only_kept_unreadable(),
        "{:?}",
        sweep.tenancy.problems()
    );
    let in_build: std::collections::HashSet<ResourceId> =
        manifests(&v2).iter().map(ResourceId::from_value).collect();
    let objects = crate::cluster::revision::keep::kept_to_rebuild(&sweep, &in_build);
    assert_eq!(
        objects.iter().map(|o| o.name.as_str()).collect::<Vec<_>>(),
        ["old"]
    );
    let record = sweep.tenancy.own_current().unwrap().to_string();
    let lock = crate::cluster::head::take(
        &client,
        crate::cluster::head::Request {
            cluster: "a".into(),
            holder: crate::cluster::head::Holder::cli("kix gc"),
            purpose: crate::cluster::head::Purpose::Gc,
            activation: None,
            expect: None,
        },
        crate::cluster::head::system_clock(),
        &|_| {},
    )
    .await
    .unwrap();
    let guarded = lock.guarded(&client);
    let records = opened.into_records().unwrap();
    crate::cluster::revision::keep::rebuild_kept(
        &guarded,
        &records.through(&guarded),
        "a",
        &record,
        objects,
    )
    .await
    .unwrap();
    lock.release().await.unwrap();

    let again = try_plan(&api, &v2, &[]).await.unwrap();
    let result = cli_run(&api, again).await.unwrap();
    assert_eq!(result.failed, 0, "{result:?}");
    assert!(read(&api, &current_map(&api).cluster_level).await.is_some());
    let pruned = try_plan(&api, &v2, &["--prune"]).await.unwrap();
    assert_eq!(names(pruned.orphans()), ["old"]);
    cli_run(&api, pruned).await.unwrap();
    assert!(api.object("ConfigMap", "old").is_none());
}

/// When this machine holds the current record's build, a read finds the
/// current record's lost revision in it. A deploy of a changed build then
/// goes ahead and prunes what the lost revision named and the new build
/// drops. This is also what lets a deploy of a `Failed` record's build go
/// ahead while a revision of the current record is lost.
#[tokio::test]
async fn the_current_build_on_this_machine_rebuilds_a_lost_revision() {
    let (api, name) = deployed().await;
    Revisions::new(&api.client()).delete(&name).await.unwrap();
    let v2 = release("a-v2", &[config_map("conf", "2")]);
    let client = api.client();
    let mut baseline = current_baseline_of(&client, "a").await;
    // What a read finds when this machine holds the current record's build.
    baseline.tenancy = baseline
        .tenancy
        .with_builds_of_records(|_, record| record.name.starts_with("a-v1").then(v1));
    let mut checked =
        crate::plan::Planner::new(crate::plan::fixtures::flags(&["--prune"]), &|_| {})
            .plan(&v2, "a", &baseline, Some(&client))
            .await
            .unwrap();
    let target = crate::plan::Target::connect(client, crate::build_source::SopsSources::Local)
        .await
        .unwrap();
    checked.ask_takes_back(&target).await;
    assert_eq!(names(checked.orphans()), ["old"]);
    let result = cli_run(&api, checked).await.unwrap();
    assert_eq!(result.failed, 0, "{result:?}");
    assert!(api.object("ConfigMap", "old").is_none());
}
