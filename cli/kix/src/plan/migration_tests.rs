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
    let client = api.client();
    let baseline = baseline(&client, cluster).await;
    Planner::new(crate::plan::fixtures::flags(&[]), &|_| {})
        .plan(graph, cluster, &baseline, Some(&client))
        .await
        .unwrap()
}

pub(crate) async fn deploy(
    api: &FakeApi,
    cluster: &str,
    graph: &StoreGraph,
) -> Result<crate::cluster::stream::DeployResult, DeployError> {
    let checked = plan(api, cluster, graph).await;
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

/// A first deploy that stops after it moved some objects leaves its record
/// `Failed` with a revision map, and the Kix cluster still read from the
/// notes. The next deploy takes in what the stopped one moved through its
/// revisions, reads the rest from the notes, and finishes the move.
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
        crate::cluster::tenancy::Source::Records
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
    assert_eq!(
        notes(&api, "ConfigMap", "shared"),
        (Some(kept.join(",")), None)
    );
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

/// The operator does not repair drift on a Kix cluster an older Kix
/// deployed last, because a repair writes no record to move it with. Its
/// deploy of a queued record moves it.
#[tokio::test]
async fn the_operator_repairs_only_a_migrated_cluster() {
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
    let refused = crate::plan::live::LivePlan::sweep(
        &api.client(),
        &record,
        &desired,
        revisions.clone(),
        false,
    )
    .await;
    let Err(err) = refused else {
        panic!("a repair of a cluster that is not migrated was planned");
    };
    assert!(
        matches!(err, crate::plan::live::LivePlanError::NotMigrated { .. }),
        "{err}"
    );
    assert!(err.to_string().contains("kix deploy a"), "{err}");
    let deploys =
        crate::plan::live::LivePlan::sweep(&api.client(), &record, &desired, revisions, true)
            .await
            .unwrap();
    assert_eq!(deploys.metadata_rewrites(), 1);
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
