//! The first deploy of a Kix cluster by this Kix: the one planner reads it
//! from the notes an older Kix wrote, and the run moves every object to
//! revisions with one migration write each.

use std::sync::Arc;

use kube::Client;
use kube::api::{DynamicObject, Patch, PatchParams};
use serde_json::{Value, json};

use crate::cluster::activation::Records;
use crate::cluster::discovery;
use crate::cluster::fake_api::FakeApi;
use crate::cluster::field_manager::{FieldManager, LEGACY};
use crate::cluster::fieldsv1;
use crate::cluster::revision::{Revision, Revisions};
use crate::cluster::scheduler::{self, DeployError, SchedulerConfig};
use crate::eval::store_graph::StoreGraph;
use crate::manifest::keys;
use crate::manifest::lifecycle::{self, PHASE_ACTIVE, PHASE_FAILED};
use crate::plan::{CheckedPlan, Planner};

fn config_map(name: &str, value: &str) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": name,
            "namespace": "app",
            "labels": { "app.kubernetes.io/managed-by": "kix" },
        },
        "data": { "k": value },
    })
}

fn deployment(name: &str) -> Value {
    json!({
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": name,
            "namespace": "app",
            "labels": { "app.kubernetes.io/managed-by": "kix" },
        },
        "spec": { "replicas": 1, "template": { "spec": { "image": "web:1" } } },
        // The fake stores what a create sends, so the Deployment is ready
        // at once. No apply owns `status`.
        "status": {
            "observedGeneration": 1,
            "replicas": 1,
            "updatedReplicas": 1,
            "readyReplicas": 1,
            "availableReplicas": 1,
            "conditions": [{ "type": "Available", "status": "True" }],
        },
    })
}

/// Return the stamped build of `manifests` and the record `record` for Kix
/// cluster `cluster`.
fn release(cluster: &str, record: &str, manifests: &[Value]) -> StoreGraph {
    let mut all = manifests.to_vec();
    all.push(json!({
        "apiVersion": keys::API_VERSION,
        "kind": lifecycle::RECORD_KIND,
        "metadata": {
            "name": record,
            "labels": { (keys::CLUSTER_LABEL): cluster },
        },
        "spec": { "cluster": cluster },
    }));
    let graph = StoreGraph::synthesize(&all, &StoreGraph::empty(cluster));
    crate::plan::fixtures::stamp(&graph).0
}

fn record_of(graph: &StoreGraph) -> Value {
    graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .find(lifecycle::is_record)
        .unwrap()
}

fn hash_of(manifest: &Value) -> String {
    keys::get(manifest, keys::IDENTITY_HASH)
        .unwrap()
        .to_string()
}

/// Put on `api` what an older Kix left after it deployed `graph` as Kix
/// cluster `cluster`, with record `phase`: the record without a revision
/// map, and each object applied under the field manager `kix` and then
/// written again with the two notes. `also` lists record hashes of other
/// deploys that the notes name too.
async fn deployed_by_an_older_kix(
    api: &FakeApi,
    cluster: &str,
    graph: &StoreGraph,
    phase: &str,
    also: &[(&str, &[&str])],
) {
    let mut record = record_of(graph);
    record["metadata"]["labels"]["app.kubernetes.io/managed-by"] = json!("kix");
    record["status"] = json!({ "phase": phase, "deployedAt": "2026-11-01T00:00:00Z" });
    let hash = hash_of(&record);
    api.insert(record);
    let client = api.client();
    let found = discovery::discover_resources(&client).await.unwrap();
    for node in graph.resources.values() {
        let manifest = &node.manifest;
        if lifecycle::is_record(manifest) {
            continue;
        }
        let rid = crate::manifest::types::ResourceId::from_value(manifest);
        let (ar, scope) = discovery::find(&found, &rid.group, &rid.kind).unwrap();
        let objects = discovery::api_for(&client, ar, scope, &rid);
        let stored = objects
            .patch(
                &rid.name,
                &PatchParams::apply(LEGACY),
                &Patch::Apply(manifest),
            )
            .await
            .unwrap();
        let applied =
            fieldsv1::applied_content_hash(&stored, &FieldManager::unmigrated(cluster)).unwrap();
        let mut named = vec![hash.clone()];
        for (name, hashes) in also {
            if *name == rid.name {
                named.extend(hashes.iter().map(|h| h.to_string()));
            }
        }
        named.sort();
        api.update_as(LEGACY, None, &rid.kind, &rid.name, |o| {
            let annotations = &mut o["metadata"]["annotations"];
            annotations[keys::ACTIVATIONS] = json!(named.join(","));
            annotations[keys::APPLIED_HASH] = json!(applied);
        });
    }
}

fn test_config() -> SchedulerConfig {
    SchedulerConfig {
        timeout: std::time::Duration::from_secs(5),
        on_error: scheduler::OnErrorPolicy::Stop,
        cancel: crate::cluster::cancel::CancelToken::new(),
        concurrency: scheduler::CONCURRENCY,
        stall: crate::cluster::watchdog::StallPolicy::off(),
        check_unchanged: false,
        names_flags: false,
    }
}

pub(crate) async fn baseline(client: &Client, cluster: &str) -> crate::plan::baseline::Baseline {
    let opened = Records::open(
        client,
        &discovery::discover_resources(client).await.unwrap(),
    )
    .unwrap();
    let tenancy = crate::cluster::tenancy::read(&opened, cluster)
        .await
        .unwrap();
    let active = opened
        .into_records()
        .unwrap()
        .active(cluster)
        .await
        .unwrap();
    crate::plan::baseline::Baseline {
        active,
        tenancy,
        ..crate::plan::baseline::Baseline::empty()
    }
}

pub(crate) async fn plan(api: &FakeApi, cluster: &str, graph: &StoreGraph) -> CheckedPlan {
    plan_with(api, cluster, graph, crate::plan::fixtures::flags(&[])).await
}

async fn plan_with(
    api: &FakeApi,
    cluster: &str,
    graph: &StoreGraph,
    flags: crate::plan::document::PlanFlags,
) -> CheckedPlan {
    let client = api.client();
    let baseline = baseline(&client, cluster).await;
    Planner::new(flags, &|_| {})
        .plan(graph, cluster, &baseline, Some(&client))
        .await
        .unwrap()
}

pub(crate) async fn deploy(
    api: &FakeApi,
    cluster: &str,
    graph: &StoreGraph,
) -> Result<crate::cluster::stream::DeployResult, DeployError> {
    deploy_with(api, cluster, graph, crate::plan::fixtures::flags(&[])).await
}

async fn deploy_with(
    api: &FakeApi,
    cluster: &str,
    graph: &StoreGraph,
    flags: crate::plan::document::PlanFlags,
) -> Result<crate::cluster::stream::DeployResult, DeployError> {
    let checked = plan_with(api, cluster, graph, flags).await;
    let client = api.client();
    let lock = crate::cluster::head::take(
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
    .await
    .unwrap();
    let lock = Arc::new(lock);
    let target = crate::plan::Target::connect(client, crate::build_source::SopsSources::Local)
        .await
        .unwrap();
    let result = checked
        .run(
            target,
            lock.clone(),
            None,
            test_config(),
            Arc::new(crate::cluster::stream::NullObserver),
        )
        .await;
    lock.release().await.unwrap();
    result
}

pub(crate) fn written(checked: &CheckedPlan) -> Vec<String> {
    let mut names: Vec<String> = checked
        .plan()
        .nodes()
        .iter()
        .filter_map(|n| n.action.written())
        .filter(|m| !lifecycle::is_record(m))
        .map(|m| crate::manifest::types::ResourceId::from_value(m).name)
        .collect();
    names.sort();
    names
}

pub(crate) fn managers(api: &FakeApi, kind: &str, name: &str) -> Vec<String> {
    let obj = api.object(kind, name).unwrap();
    let mut out: Vec<String> = obj["metadata"]["managedFields"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|e| {
            format!(
                "{}:{}",
                e["manager"].as_str().unwrap_or_default(),
                e["operation"].as_str().unwrap_or_default()
            )
        })
        .collect();
    out.sort();
    out
}

pub(crate) fn notes(api: &FakeApi, kind: &str, name: &str) -> (Option<String>, Option<String>) {
    let obj = api.object(kind, name).unwrap();
    let annotations = &obj["metadata"]["annotations"];
    let read = |key: &str| annotations[key].as_str().map(str::to_string);
    (read(keys::ACTIVATIONS), read(keys::APPLIED_HASH))
}

/// Return the revisions the record of `graph` of Kix cluster `cluster` names,
/// and its kept-orphans revision, as `(built, kept)`.
async fn revisions_of(
    api: &FakeApi,
    cluster: &str,
    graph: &StoreGraph,
) -> (Vec<Revision>, Option<Revision>) {
    let client = api.client();
    let name = record_of(graph)["metadata"]["name"]
        .as_str()
        .unwrap()
        .to_string();
    let name = name.as_str();
    let record = crate::cluster::activation::Record::of(
        &serde_json::from_value::<DynamicObject>(api.object(lifecycle::RECORD_KIND, name).unwrap())
            .unwrap(),
    );
    let map = record.revisions.unwrap().unwrap();
    let listed = Revisions::new(&client)
        .list(cluster)
        .await
        .unwrap()
        .readable;
    let find = |n: &str| listed.iter().find(|r| r.name == n).cloned().unwrap();
    let built = map
        .instances
        .values()
        .chain(std::iter::once(&map.cluster_level))
        .map(|n| find(n))
        .collect();
    (built, map.kept_orphans.as_deref().map(find))
}

/// Return the objects `revisions` name, leaving out the deployment record.
fn named(revisions: &[Revision]) -> Vec<String> {
    let mut out: Vec<String> = revisions
        .iter()
        .flat_map(|r| r.spec.objects.iter())
        .filter(|o| o.kind != lifecycle::RECORD_KIND)
        .map(|o| o.name.clone())
        .collect();
    out.sort();
    out
}

/// The first deploy of a Kix cluster an older Kix deployed plans from the
/// notes, shows the metadata it rewrites, and leaves every object with one
/// `Apply` entry under the cluster's manager and neither note. Revisions
/// name every object, the kept orphan included, and carry the applied
/// hashes from the notes. The Deployment's `spec` is untouched, so its Pods
/// do not restart, and a second plan has nothing to do.
#[tokio::test]
async fn the_first_deploy_moves_every_object_to_revisions() {
    let api = FakeApi::new([]);
    api.track_owners();
    let old = release(
        "a",
        "a-r0",
        &[
            config_map("keep", "1"),
            config_map("gone", "1"),
            deployment("web"),
        ],
    );
    deployed_by_an_older_kix(&api, "a", &old, PHASE_ACTIVE, &[]).await;
    let keep_applied = notes(&api, "ConfigMap", "keep").1.unwrap();
    let web_spec = api.object("Deployment", "web").unwrap()["spec"].clone();
    let new = release(
        "a",
        "a-r1",
        &[
            config_map("keep", "1"),
            deployment("web"),
            config_map("new", "1"),
        ],
    );

    let checked = plan(&api, "a", &new).await;
    assert_eq!(written(&checked), ["new"]);
    // `keep`, `web`, and the orphan `gone`, which the warn-only prune keeps.
    assert_eq!(checked.metadata_rewrites(), 3);
    assert_eq!(checked.orphans().len(), 1);

    deploy(&api, "a", &new).await.unwrap();
    for (kind, name) in [
        ("ConfigMap", "keep"),
        ("ConfigMap", "gone"),
        ("Deployment", "web"),
        ("ConfigMap", "new"),
    ] {
        assert_eq!(managers(&api, kind, name), ["kix/a:Apply"], "{name}");
        assert_eq!(notes(&api, kind, name), (None, None), "{name}");
    }
    assert_eq!(api.object("Deployment", "web").unwrap()["spec"], web_spec);

    let (built, kept) = revisions_of(&api, "a", &new).await;
    assert_eq!(named(&built), ["keep", "new", "web"]);
    assert_eq!(named(&kept.into_iter().collect::<Vec<_>>()), ["gone"]);
    let keep = built
        .iter()
        .flat_map(|r| r.spec.objects.iter().map(move |o| (r, o)))
        .find(|(_, o)| o.name == "keep")
        .unwrap();
    assert_eq!(keep.0.applied.get(&keep.1.hash), Some(&keep_applied));

    // The kept orphan stays an orphan the warn-only prune reports.
    let again = plan(&api, "a", &new).await;
    assert!(written(&again).is_empty(), "{:?}", written(&again));
    assert_eq!(again.metadata_rewrites(), 0);
    assert_eq!(again.orphans().len(), 1);
}

/// A first deploy gives the old records revisions before it writes any
/// object, so one that stops after it tidied some objects leaves the old
/// current record naming every object through its revisions, and its own
/// record `Failed` with a map. The next deploy takes in what the stopped one
/// applied, and finishes tidying.
#[tokio::test]
async fn a_migration_that_stops_is_finished_by_the_next_deploy() {
    let api = FakeApi::new([]);
    api.track_owners();
    let old = release(
        "a",
        "a-r0",
        &[
            config_map("changed", "1"),
            config_map("same", "1"),
            config_map("gone", "1"),
        ],
    );
    deployed_by_an_older_kix(&api, "a", &old, PHASE_ACTIVE, &[]).await;
    let stopping = release(
        "a",
        "a-r1",
        &[
            config_map("changed", "2"),
            config_map("same", "1"),
            config_map("broken", "1"),
        ],
    );
    // The read and the apply of `broken` fail, so the run stops before its
    // end.
    api.fail_next("/api/v1/namespaces/app/configmaps/broken", 2, 500);
    assert!(deploy(&api, "a", &stopping).await.is_err());
    let stopped = record_of(&stopping)["metadata"]["name"]
        .as_str()
        .unwrap()
        .to_string();
    let record = api.object(lifecycle::RECORD_KIND, &stopped).unwrap();
    assert_eq!(record["status"]["phase"], PHASE_FAILED);
    assert!(record["status"]["revisions"].is_object(), "{record}");
    // The applied object moved before its apply. The unchanged one and the
    // orphan wait for a deploy that finishes.
    assert_eq!(managers(&api, "ConfigMap", "changed"), ["kix/a:Apply"]);
    assert_eq!(notes(&api, "ConfigMap", "changed"), (None, None));
    assert!(notes(&api, "ConfigMap", "same").0.is_some());
    assert!(notes(&api, "ConfigMap", "gone").0.is_some());
    let tenancy = baseline(&api.client(), "a").await.tenancy;
    assert_eq!(
        tenancy.own_source(),
        crate::cluster::tenancy::Source::Revisions
    );

    let finishing = release(
        "a",
        "a-r2",
        &[
            config_map("changed", "2"),
            config_map("same", "1"),
            config_map("broken", "1"),
        ],
    );
    let checked = plan(&api, "a", &finishing).await;
    assert_eq!(checked.consumed_failed(), [stopped]);
    assert_eq!(checked.orphans().len(), 1, "{:?}", checked.orphans());
    deploy(&api, "a", &finishing).await.unwrap();
    for name in ["changed", "same", "gone", "broken"] {
        assert_eq!(managers(&api, "ConfigMap", name), ["kix/a:Apply"], "{name}");
        assert_eq!(notes(&api, "ConfigMap", name), (None, None), "{name}");
    }
    let (_, kept) = revisions_of(&api, "a", &finishing).await;
    assert_eq!(named(&kept.into_iter().collect::<Vec<_>>()), ["gone"]);
    let tenancy = baseline(&api.client(), "a").await.tenancy;
    assert_eq!(
        tenancy.own_source(),
        crate::cluster::tenancy::Source::Revisions
    );
}

/// While Kix cluster `b`, which an older Kix still deploys, shares an
/// object with `a`, the first deploy of `a` by this Kix keeps the note
/// with its record's hash beside `b`'s, and leaves the entries under
/// `kix`, adding its own. Once `b` moves too, the object holds one entry
/// for each Kix cluster and no note, and `a` has nothing left to rewrite.
#[tokio::test]
async fn a_shared_object_keeps_its_note_until_the_other_cluster_moves() {
    let api = FakeApi::new([]);
    api.track_owners();
    let b_old = release(
        "b",
        "b-r0",
        &[config_map("shared", "1"), config_map("only-b", "1")],
    );
    let b_hash = hash_of(&record_of(&b_old));
    let a_old = release(
        "a",
        "a-r0",
        &[config_map("shared", "1"), config_map("only-a", "1")],
    );
    let a_hash = hash_of(&record_of(&a_old));
    deployed_by_an_older_kix(&api, "b", &b_old, PHASE_ACTIVE, &[]).await;
    deployed_by_an_older_kix(&api, "a", &a_old, PHASE_ACTIVE, &[("shared", &[&b_hash])]).await;
    let a_new = release(
        "a",
        "a-r1",
        &[config_map("shared", "1"), config_map("only-a", "1")],
    );
    let a_new_hash = hash_of(&record_of(&a_new));

    deploy(&api, "a", &a_new).await.unwrap();
    assert_eq!(managers(&api, "ConfigMap", "only-a"), ["kix/a:Apply"]);
    assert_eq!(notes(&api, "ConfigMap", "only-a"), (None, None));
    let mut kept = [a_new_hash.clone(), b_hash.clone()];
    kept.sort();
    // The applied-hash note stays for the older Kix, which reads drift from
    // it.
    let (note, applied) = notes(&api, "ConfigMap", "shared");
    assert_eq!(note, Some(kept.join(",")));
    assert!(applied.is_some());
    let shared = managers(&api, "ConfigMap", "shared");
    assert!(shared.contains(&"kix:Apply".to_string()), "{shared:?}");
    assert!(shared.contains(&"kix/a:Apply".to_string()), "{shared:?}");
    // `b`'s own object is left as the older Kix wrote it.
    assert!(notes(&api, "ConfigMap", "only-b").0.is_some());
    assert_ne!(Some(a_hash), notes(&api, "ConfigMap", "shared").0);

    let b_new = release(
        "b",
        "b-r1",
        &[config_map("shared", "1"), config_map("only-b", "1")],
    );
    deploy(&api, "b", &b_new).await.unwrap();
    assert_eq!(
        managers(&api, "ConfigMap", "shared"),
        ["kix/a:Apply", "kix/b:Apply"]
    );
    assert_eq!(notes(&api, "ConfigMap", "shared"), (None, None));
    assert_eq!(managers(&api, "ConfigMap", "only-b"), ["kix/b:Apply"]);

    let again = plan(&api, "a", &a_new).await;
    assert_eq!(again.metadata_rewrites(), 0);
    assert!(written(&again).is_empty(), "{:?}", written(&again));
}

/// The operator's repair of a Kix cluster an older Kix deployed plans
/// after the same conversion as a deploy, so it tidies the objects too.
#[tokio::test]
async fn the_operator_repair_reads_the_records_after_their_conversion() {
    let api = FakeApi::new([]);
    api.track_owners();
    let old = release("a", "a-r0", &[config_map("web", "1")]);
    deployed_by_an_older_kix(&api, "a", &old, PHASE_ACTIVE, &[]).await;
    let name = record_of(&old)["metadata"]["name"]
        .as_str()
        .unwrap()
        .to_string();
    let record: DynamicObject =
        serde_json::from_value(api.object(lifecycle::RECORD_KIND, &name).unwrap()).unwrap();
    let desired: Vec<Value> = old
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .filter(|m| !lifecycle::is_record(m))
        .collect();
    let revisions = Some(crate::cluster::revision::RevisionSet::of("a", &old));
    let repair =
        crate::plan::live::LivePlan::sweep(&api.client(), &record, &desired, revisions, false)
            .await
            .unwrap();
    assert_eq!(repair.metadata_rewrites(), 1);
    assert_eq!(repair.applies(), 0);
}

/// A Kix cluster that stops deploying an object another Kix cluster still
/// deploys keeps it and gives up its own fields on it, once, so its entry
/// does not keep the object on the cluster for ever.
#[tokio::test]
async fn an_orphan_another_cluster_deploys_is_released() {
    let api = FakeApi::new([]);
    api.track_owners();
    let a = release(
        "a",
        "a-r1",
        &[config_map("shared", "1"), config_map("only-a", "1")],
    );
    let b = release(
        "b",
        "b-r1",
        &[config_map("shared", "1"), config_map("only-b", "1")],
    );
    deploy(&api, "a", &a).await.unwrap();
    deploy(&api, "b", &b).await.unwrap();
    assert_eq!(
        managers(&api, "ConfigMap", "shared"),
        ["kix/a:Apply", "kix/b:Apply"]
    );

    let a_without = release("a", "a-r2", &[config_map("only-a", "1")]);
    let checked = plan(&api, "a", &a_without).await;
    assert!(checked.orphans().is_empty(), "{:?}", checked.orphans());
    assert_eq!(checked.shared_orphans().len(), 1);
    deploy(&api, "a", &a_without).await.unwrap();
    assert_eq!(managers(&api, "ConfigMap", "shared"), ["kix/b:Apply"]);
    assert_eq!(
        api.object("ConfigMap", "shared").unwrap()["data"]["k"],
        json!("1")
    );
    let requests = api.requests().len();
    deploy(&api, "a", &a_without).await.unwrap();
    let applies_to_shared = api.requests()[requests..]
        .iter()
        .filter(|r| r.starts_with("PATCH") && r.contains("/configmaps/shared"))
        .count();
    assert_eq!(applies_to_shared, 0);
}

/// A Kix cluster that stops deploying an object another Kix cluster
/// deploys does not touch the entry under `kix` when it has no entry of its
/// own on the object: the entry may hold the other cluster's fields. Here
/// `b` moved first, and as an operator would, never applied the shared
/// object under its own name. `a`'s release then writes nothing, and the
/// object keeps its values.
#[tokio::test]
async fn a_release_leaves_the_legacy_entry_of_another_cluster() {
    let api = FakeApi::new([]);
    api.track_owners();
    let b_old = release("b", "b-r0", &[config_map("shared", "1")]);
    let b_hash = hash_of(&record_of(&b_old));
    let a_old = release(
        "a",
        "a-r0",
        &[config_map("shared", "1"), config_map("only-a", "1")],
    );
    deployed_by_an_older_kix(&api, "b", &b_old, PHASE_ACTIVE, &[]).await;
    deployed_by_an_older_kix(&api, "a", &a_old, PHASE_ACTIVE, &[("shared", &[&b_hash])]).await;
    // `b` moves. The fields of the shared object sit under `kix` for `a`,
    // which an older Kix still deploys, so the operator applies it without
    // force, as the CLI does.
    let b_new = release("b", "b-r1", &[config_map("shared", "1")]);
    let b_record = record_of(&b_new);
    let mut b_record_live = b_record.clone();
    b_record_live["metadata"]["labels"]["app.kubernetes.io/managed-by"] = json!("kix");
    b_record_live["spec"]["source"] = json!("/nix/store/b");
    let b_live: DynamicObject = serde_json::from_value(b_record_live).unwrap();
    let desired: Vec<Value> = b_new
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .filter(|m| !lifecycle::is_record(m))
        .collect();
    let operator = crate::plan::live::LivePlan::sweep(
        &api.client(),
        &b_live,
        &desired,
        Some(crate::cluster::revision::RevisionSet::of("b", &b_new)),
        true,
    )
    .await
    .unwrap();
    assert_eq!(operator.applies(), 1);
    deploy(&api, "b", &b_new).await.unwrap();
    api.patch_object("ConfigMap", "shared", |o| {
        let entries = o["metadata"]["managedFields"].as_array_mut().unwrap();
        entries.retain(|e| e["manager"] != "kix/b");
    });
    assert_eq!(
        managers(&api, "ConfigMap", "shared"),
        ["kix:Apply", "kix:Update"]
    );

    let a_new = release("a", "a-r1", &[config_map("only-a", "1")]);
    let checked = plan(&api, "a", &a_new).await;
    assert_eq!(checked.shared_orphans().len(), 1);
    deploy(&api, "a", &a_new).await.unwrap();
    assert_eq!(
        managers(&api, "ConfigMap", "shared"),
        ["kix:Apply", "kix:Update"]
    );
    assert_eq!(
        api.object("ConfigMap", "shared").unwrap()["data"]["k"],
        json!("1")
    );
}

/// A release that fails leaves the object in the record's kept-orphans
/// revision, so the next deploy finds it again and gives up the fields.
#[tokio::test]
async fn a_release_that_fails_is_tried_again() {
    let api = FakeApi::new([]);
    api.track_owners();
    let a = release(
        "a",
        "a-r1",
        &[config_map("shared", "1"), config_map("only-a", "1")],
    );
    let b = release("b", "b-r1", &[config_map("shared", "1")]);
    deploy(&api, "a", &a).await.unwrap();
    deploy(&api, "b", &b).await.unwrap();
    let a_without = release("a", "a-r2", &[config_map("only-a", "1")]);
    // The release reads the object first, and that read fails.
    api.fail_next("/api/v1/namespaces/app/configmaps/shared", 1, 500);
    deploy(&api, "a", &a_without).await.unwrap();
    assert_eq!(
        managers(&api, "ConfigMap", "shared"),
        ["kix/a:Apply", "kix/b:Apply"]
    );
    let (_, kept) = revisions_of(&api, "a", &a_without).await;
    assert_eq!(named(&kept.into_iter().collect::<Vec<_>>()), ["shared"]);

    let a_again = release(
        "a",
        "a-r3",
        &[config_map("only-a", "1"), config_map("other", "1")],
    );
    deploy(&api, "a", &a_again).await.unwrap();
    assert_eq!(managers(&api, "ConfigMap", "shared"), ["kix/b:Apply"]);
}

/// The first deploy gives the old current record revisions before it
/// writes any object. When an object's migration write succeeds and its
/// apply then fails, the old record still names it through its revisions,
/// so a later build that drops it prunes it as an orphan.
#[tokio::test]
async fn an_object_whose_apply_failed_after_its_tidy_is_still_named() {
    let api = FakeApi::new([]);
    api.track_owners();
    let old = release(
        "a",
        "a-r0",
        &[config_map("edited", "1"), config_map("keep", "1")],
    );
    deployed_by_an_older_kix(&api, "a", &old, PHASE_ACTIVE, &[]).await;
    // Someone takes the value with another field manager, so the changed
    // build's apply, which is not forced, is refused.
    api.update_as("kubectl", None, "ConfigMap", "edited", |o| {
        o["data"]["k"] = json!("by-hand");
    });
    let changing = release(
        "a",
        "a-r1",
        &[config_map("edited", "2"), config_map("keep", "1")],
    );
    assert!(deploy(&api, "a", &changing).await.is_err());
    assert_eq!(notes(&api, "ConfigMap", "edited").0, None);

    let dropping = release("a", "a-r2", &[config_map("keep", "1")]);
    let checked = plan(&api, "a", &dropping).await;
    let orphans: Vec<&str> = checked.orphans().iter().map(|r| r.name.as_str()).collect();
    assert_eq!(orphans, ["edited"]);
}

/// On the first deploy, an object drifted by hand is reverted: its
/// migration write tests the version the plan read and hands the version
/// it leaves to the forced apply, so the apply does not read the write as
/// a change made after the plan.
#[tokio::test]
async fn a_drifted_object_is_reverted_on_the_first_deploy() {
    let api = FakeApi::new([]);
    api.track_owners();
    let old = release("a", "a-r0", &[config_map("web", "1")]);
    deployed_by_an_older_kix(&api, "a", &old, PHASE_ACTIVE, &[]).await;
    api.update_as("kubectl", None, "ConfigMap", "web", |o| {
        o["data"]["k"] = json!("by-hand");
    });
    let same = release("a", "a-r1", &[config_map("web", "1")]);
    deploy(&api, "a", &same).await.unwrap();
    let web = api.object("ConfigMap", "web").unwrap();
    assert_eq!(web["data"]["k"], json!("1"));
    assert_eq!(managers(&api, "ConfigMap", "web"), ["kix/a:Apply"]);
}

/// A build that adds an object another Kix cluster applied under `kix`
/// does not read that entry as its own: the plan applies the object, which
/// adds the cluster's own entry, and keeps the note for the older Kix.
#[tokio::test]
async fn an_object_another_cluster_applied_is_applied_when_a_build_adds_it() {
    let api = FakeApi::new([]);
    api.track_owners();
    let b_old = release("b", "b-r0", &[config_map("shared", "1")]);
    let b_hash = hash_of(&record_of(&b_old));
    deployed_by_an_older_kix(&api, "b", &b_old, PHASE_ACTIVE, &[]).await;
    let a_old = release("a", "a-r0", &[config_map("only-a", "1")]);
    deployed_by_an_older_kix(&api, "a", &a_old, PHASE_ACTIVE, &[]).await;
    let a_new = release(
        "a",
        "a-r1",
        &[config_map("only-a", "1"), config_map("shared", "1")],
    );
    let a_new_hash = hash_of(&record_of(&a_new));
    let checked = plan(&api, "a", &a_new).await;
    assert!(
        written(&checked).contains(&"shared".to_string()),
        "{:?}",
        written(&checked)
    );
    deploy(&api, "a", &a_new).await.unwrap();
    assert_eq!(
        managers(&api, "ConfigMap", "shared"),
        ["kix/a:Apply", "kix:Apply", "kix:Update"]
    );
    let mut kept = [a_new_hash, b_hash];
    kept.sort();
    assert_eq!(notes(&api, "ConfigMap", "shared").0, Some(kept.join(",")));
}

/// A Kix cluster an older operator drives: an operator-driven current
/// record, a queued one, and one the operator stopped deploying. Return the
/// next build.
async fn handed_to_an_older_operator(api: &FakeApi) -> StoreGraph {
    // An operator older than the features annotation left the CRD without
    // it.
    api.insert(json!({
        "apiVersion": "apiextensions.k8s.io/v1",
        "kind": "CustomResourceDefinition",
        "metadata": { "name": keys::ACTIVATIONS_CRD },
        "spec": { "versions": [{ "name": "v1alpha1", "served": true, "storage": true }] },
        "status": { "conditions": [{ "type": "Established", "status": "True" }] },
    }));
    let old = release("a", "a-r0", &[config_map("web", "1")]);
    deployed_by_an_older_kix(api, "a", &old, PHASE_ACTIVE, &[]).await;
    let current = record_of(&old)["metadata"]["name"]
        .as_str()
        .unwrap()
        .to_string();
    let source = json!({ "type": "storePath", "path": "/nix/store/x" });
    api.patch_object(lifecycle::RECORD_KIND, &current, |o| {
        o["spec"]["source"] = source.clone();
    });
    for (name, phase) in [("a-queued", ""), ("a-deploying", "Deploying")] {
        api.insert(json!({
            "apiVersion": keys::API_VERSION,
            "kind": lifecycle::RECORD_KIND,
            "metadata": {
                "name": name,
                "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): "a" },
                "annotations": { (keys::IDENTITY_HASH): name },
            },
            "spec": { "cluster": "a", "source": source },
            "status": { "phase": phase },
        }));
    }
    release("a", "a-r1", &[config_map("web", "2")])
}

fn phase(api: &FakeApi, name: &str) -> String {
    api.object(lifecycle::RECORD_KIND, name).unwrap()["status"]["phase"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

/// Without `--operator-removed`, a Kix cluster an older operator drives is
/// refused, and the planner changes nothing. With it, the deploy takes the
/// cluster back before it plans: the queued record is `Superseded`, the
/// deploying one `Failed`, and no record names a build for the operator.
/// After that deploy, no command is refused, without the flag.
#[tokio::test]
async fn a_deploy_with_operator_removed_takes_the_cluster_back_for_good() {
    let api = FakeApi::new([]);
    api.track_owners();
    let new = handed_to_an_older_operator(&api).await;
    let client = api.client();
    let settle = crate::plan::planner::Settle {
        command: "kix deploy",
        purpose: crate::cluster::head::Purpose::Deploy,
    };
    let refused = crate::plan::planner::refuse_older_operator(&client, "a")
        .await
        .unwrap_err();
    assert!(
        matches!(refused, crate::plan::PlanError::OperatorWithoutRevisions(_)),
        "{refused}"
    );
    let text = refused.to_string();
    assert!(
        text.starts_with("[K9557]") && text.contains("kix deploy a --operator-removed"),
        "{text}"
    );
    Planner::new(crate::plan::fixtures::flags(&[]), &|_| {})
        .take_back(&client, "a", &settle)
        .await
        .unwrap();
    assert_eq!(phase(&api, "a-queued"), "");
    assert!(
        crate::plan::planner::refuse_older_operator(&client, "a")
            .await
            .is_err()
    );

    let flags = crate::plan::document::PlanFlags {
        operator_removed: true,
        ..crate::plan::fixtures::flags(&[])
    };
    let reported = std::sync::Mutex::new(Vec::new());
    let report = |event: crate::plan::PlanEvent<'_>| {
        if let crate::plan::PlanEvent::TookBack { taken, .. } = event {
            reported.lock().unwrap().push(taken.clone());
        }
    };
    Planner::new(flags.clone(), &report)
        .take_back(&client, "a", &settle)
        .await
        .unwrap();
    let taken = reported.lock().unwrap().clone();
    assert_eq!(taken.len(), 1);
    assert_eq!(taken[0].superseded, ["a-queued"]);
    assert_eq!(taken[0].failed, ["a-deploying"]);
    assert!(taken[0].current.is_some());
    assert_eq!(phase(&api, "a-queued"), "Superseded");
    assert_eq!(phase(&api, "a-deploying"), "Failed");
    crate::plan::planner::refuse_older_operator(&client, "a")
        .await
        .unwrap();
    // A second run finds nothing to take back.
    Planner::new(flags, &report)
        .take_back(&client, "a", &settle)
        .await
        .unwrap();
    assert_eq!(reported.lock().unwrap().len(), 1);

    deploy(&api, "a", &new).await.unwrap();
    crate::plan::planner::refuse_older_operator(&client, "a")
        .await
        .unwrap();
}

/// Insert a `Superseded` record of Kix cluster `cluster` with identity hash
/// `hash` and no map, as an older Kix left one of its earlier deploys.
fn superseded_by_an_older_kix(api: &FakeApi, cluster: &str, hash: &str) {
    api.insert(json!({
        "apiVersion": keys::API_VERSION,
        "kind": lifecycle::RECORD_KIND,
        "metadata": {
            "name": format!("{cluster}-{hash}"),
            "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): cluster },
            "annotations": { (keys::IDENTITY_HASH): hash },
        },
        "spec": { "cluster": cluster },
        "status": { "phase": lifecycle::PHASE_SUPERSEDED, "deployedAt": "2026-10-01T00:00:00Z" },
    }));
}

/// An older Kix left the hashes of earlier, `Superseded` records of both
/// clusters in a shared object's note. Those records keep nothing: once
/// both clusters deploy with this Kix, the object holds one entry for each
/// and no note.
#[tokio::test]
async fn superseded_records_an_older_kix_left_keep_no_note() {
    let api = FakeApi::new([]);
    api.track_owners();
    superseded_by_an_older_kix(&api, "a", "a-history");
    superseded_by_an_older_kix(&api, "b", "b-history");
    let b_old = release("b", "b-r0", &[config_map("shared", "1")]);
    let b_hash = hash_of(&record_of(&b_old));
    let a_old = release("a", "a-r0", &[config_map("shared", "1")]);
    deployed_by_an_older_kix(&api, "b", &b_old, PHASE_ACTIVE, &[]).await;
    deployed_by_an_older_kix(
        &api,
        "a",
        &a_old,
        PHASE_ACTIVE,
        &[("shared", &[&b_hash, "a-history", "b-history"])],
    )
    .await;

    deploy(
        &api,
        "b",
        &release("b", "b-r1", &[config_map("shared", "1")]),
    )
    .await
    .unwrap();
    deploy(
        &api,
        "a",
        &release("a", "a-r1", &[config_map("shared", "1")]),
    )
    .await
    .unwrap();
    assert_eq!(notes(&api, "ConfigMap", "shared"), (None, None));
    let shared = managers(&api, "ConfigMap", "shared");
    assert!(
        shared.contains(&"kix/a:Apply".to_string()) && shared.contains(&"kix/b:Apply".to_string()),
        "{shared:?}"
    );
    assert!(!shared.iter().any(|m| m.starts_with("kix:")), "{shared:?}");
}

/// Run the operator's repair of the record of `graph`, the current record
/// of Kix cluster `cluster`, under the deploy lock.
async fn repair(api: &FakeApi, cluster: &str, graph: &StoreGraph) {
    let name = record_of(graph)["metadata"]["name"]
        .as_str()
        .unwrap()
        .to_string();
    let record: DynamicObject =
        serde_json::from_value(api.object(lifecycle::RECORD_KIND, &name).unwrap()).unwrap();
    let desired: Vec<Value> = graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .filter(|m| !lifecycle::is_record(m))
        .collect();
    let client = api.client();
    let plan = crate::plan::live::LivePlan::sweep(
        &client,
        &record,
        &desired,
        Some(crate::cluster::revision::RevisionSet::of(cluster, graph)),
        false,
    )
    .await
    .unwrap();
    let lock = crate::cluster::head::take(
        &client,
        crate::cluster::head::Request {
            cluster: cluster.into(),
            holder: crate::cluster::head::Holder::operator("kix-system", None),
            purpose: crate::cluster::head::Purpose::Repair,
            activation: Some(name),
            expect: None,
        },
        crate::cluster::head::system_clock(),
        &|_| {},
    )
    .await
    .unwrap();
    let lock = Arc::new(lock);
    plan.run(
        lock.clone(),
        false,
        test_config(),
        Arc::new(crate::cluster::stream::NullObserver),
    )
    .await
    .unwrap();
    lock.release().await.unwrap();
}

/// Two Kix clusters the operator drives share an object an older Kix
/// applied for both. Neither has an entry of its own on it, so neither
/// repair reads a conflict from ownership: each applies without force, and
/// the object ends with one entry for each Kix cluster.
#[tokio::test]
async fn two_operator_driven_clusters_sharing_an_object_both_get_their_own_entry() {
    let api = FakeApi::new([]);
    api.track_owners();
    let b = release("b", "b-r0", &[config_map("shared", "1")]);
    let b_hash = hash_of(&record_of(&b));
    let a = release("a", "a-r0", &[config_map("shared", "1")]);
    deployed_by_an_older_kix(&api, "b", &b, PHASE_ACTIVE, &[]).await;
    deployed_by_an_older_kix(&api, "a", &a, PHASE_ACTIVE, &[("shared", &[&b_hash])]).await;

    repair(&api, "a", &a).await;
    let shared = managers(&api, "ConfigMap", "shared");
    assert!(shared.contains(&"kix/a:Apply".to_string()), "{shared:?}");
    repair(&api, "b", &b).await;
    let shared = managers(&api, "ConfigMap", "shared");
    assert!(
        shared.contains(&"kix/a:Apply".to_string()) && shared.contains(&"kix/b:Apply".to_string()),
        "{shared:?}"
    );
}

/// A deploy with `--skip-orphan-check` writes nothing to orphans, so it
/// does not release an orphan another Kix cluster still deploys. Its
/// record lists the orphan, and the next deploy releases it.
#[tokio::test]
async fn a_skipped_orphan_check_lists_the_shared_orphans_for_the_next_deploy() {
    let api = FakeApi::new([]);
    api.track_owners();
    let a = release(
        "a",
        "a-r1",
        &[config_map("shared", "1"), config_map("only-a", "1")],
    );
    let b = release("b", "b-r1", &[config_map("shared", "1")]);
    deploy(&api, "a", &a).await.unwrap();
    deploy(&api, "b", &b).await.unwrap();
    let a_without = release("a", "a-r2", &[config_map("only-a", "1")]);
    let skip = crate::plan::document::PlanFlags {
        prune: crate::cluster::scheduler::PrunePolicy::Skip,
        ..crate::plan::fixtures::flags(&[])
    };
    deploy_with(&api, "a", &a_without, skip).await.unwrap();
    assert_eq!(
        managers(&api, "ConfigMap", "shared"),
        ["kix/a:Apply", "kix/b:Apply"]
    );
    let (_, kept) = revisions_of(&api, "a", &a_without).await;
    assert_eq!(named(&kept.into_iter().collect::<Vec<_>>()), ["shared"]);

    let a_again = release(
        "a",
        "a-r3",
        &[config_map("only-a", "1"), config_map("other", "1")],
    );
    deploy(&api, "a", &a_again).await.unwrap();
    assert_eq!(managers(&api, "ConfigMap", "shared"), ["kix/b:Apply"]);
}

/// When the hashes of what a run applied cannot be written, the run stops
/// before it finalizes: its record is `Failed`, the previous record stays
/// current with its revisions, and the next deploy finishes the record.
#[tokio::test]
async fn a_run_that_cannot_record_its_applied_hashes_stops_before_it_finalizes() {
    let api = FakeApi::new([]);
    api.track_owners();
    let r1 = release("a", "a-r1", &[config_map("web", "1")]);
    deploy(&api, "a", &r1).await.unwrap();
    let r2 = release("a", "a-r2", &[config_map("web", "2")]);
    let revision = crate::cluster::revision::RevisionSet::of("a", &r2)
        .cluster_level
        .name;
    let version = keys::API_VERSION.rsplit_once('/').unwrap().1;
    api.fail_next(
        &format!(
            "/apis/{}/{version}/{}/{revision}/status",
            keys::GROUP,
            crate::cluster::revision::PLURAL
        ),
        1,
        500,
    );
    let err = deploy(&api, "a", &r2).await.unwrap_err();
    assert!(
        matches!(err, DeployError::AppliedNotRecorded { .. }),
        "{err}"
    );
    let phase = |graph: &StoreGraph| {
        let name = record_of(graph)["metadata"]["name"]
            .as_str()
            .unwrap()
            .to_string();
        api.object(lifecycle::RECORD_KIND, &name).unwrap()["status"]["phase"]
            .as_str()
            .unwrap()
            .to_string()
    };
    assert_eq!(phase(&r2), PHASE_FAILED);
    assert_eq!(phase(&r1), PHASE_ACTIVE);
    let (old, _) = revisions_of(&api, "a", &r1).await;
    assert!(!old.is_empty());

    deploy(&api, "a", &r2).await.unwrap();
    assert_eq!(phase(&r2), PHASE_ACTIVE);
    let again = plan(&api, "a", &r2).await;
    assert!(written(&again).is_empty(), "{:?}", written(&again));
}

/// A deploy of the build an older Kix deployed last, under the same record
/// name, replaces the map the conversion gave the record with the build's.
/// The converted revision names one more object, found through its note,
/// so the two differ. The applied hashes are carried from the converted
/// revisions, and the next plan finds every object in sync.
#[tokio::test]
async fn a_redeploy_of_the_converted_record_keeps_its_applied_hashes() {
    let api = FakeApi::new([]);
    api.track_owners();
    let old = release("a", "a-r0", &[config_map("web", "1")]);
    deployed_by_an_older_kix(&api, "a", &old, PHASE_ACTIVE, &[]).await;
    let hash = hash_of(&record_of(&old));
    let mut extra = config_map("extra", "1");
    extra["metadata"]["labels"] = json!({ "app.kubernetes.io/managed-by": "kix" });
    extra["metadata"]["annotations"] = json!({
        (keys::IDENTITY_HASH): "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        (keys::ACTIVATIONS): hash,
    });
    api.insert(extra);

    deploy(&api, "a", &old).await.unwrap();
    let again = plan(&api, "a", &old).await;
    assert!(written(&again).is_empty(), "{:?}", written(&again));
}
