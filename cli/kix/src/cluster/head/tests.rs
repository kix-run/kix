//! Tests of the deploy lock, against the in-memory apiserver and on paused
//! time, so the lease, the deadline, and the takeover run without real
//! sleeps.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Utc};
use kube::Client;
use kube::api::{Api, DynamicObject, PostParams};
use serde_json::{Value, json};

use super::lock::decide;
use super::*;
use crate::cluster::activation::Record;
use crate::cluster::cancel::CancelToken;
use crate::cluster::fake_api::FakeApi;

const CLUSTER: &str = "c1";

/// A wall clock that follows tokio's paused time, moved by `offset` to model
/// a machine that slept while its monotonic clock did not count the time.
struct TestClock {
    start: (DateTime<Utc>, tokio::time::Instant),
    offset: Mutex<chrono::Duration>,
}

impl Default for TestClock {
    fn default() -> Self {
        TestClock {
            start: (Utc::now(), tokio::time::Instant::now()),
            offset: Mutex::new(chrono::Duration::zero()),
        }
    }
}

impl TestClock {
    fn jump(&self, by: Duration) {
        *self.offset.lock().unwrap() += chrono::Duration::from_std(by).unwrap();
    }
}

impl Clock for TestClock {
    fn wall(&self) -> DateTime<Utc> {
        let (wall, mono) = self.start;
        wall + chrono::Duration::from_std(mono.elapsed()).unwrap() + *self.offset.lock().unwrap()
    }
}

fn holder(id: &str) -> Holder {
    Holder {
        id: id.into(),
        hint: format!("kix deploy by {id}"),
        program: Program::Cli,
    }
}

fn request(id: &str, activation: Option<&str>) -> Request {
    Request {
        cluster: CLUSTER.into(),
        holder: holder(id),
        purpose: Purpose::Deploy,
        activation: activation.map(str::to_string),
        expect: None,
    }
}

fn record(name: &str, phase: &str) -> Value {
    json!({
        "apiVersion": crate::manifest::keys::API_VERSION,
        "kind": "Activation",
        "metadata": {
            "name": name,
            "labels": {
                "app.kubernetes.io/managed-by": "kix",
                (crate::manifest::keys::CLUSTER_LABEL): CLUSTER,
            },
        },
        "status": { "phase": phase },
    })
}

fn head(status: Value) -> Value {
    json!({
        "apiVersion": crate::manifest::keys::API_VERSION,
        "kind": KIND,
        "metadata": { "name": CLUSTER, "labels": { (crate::manifest::keys::CLUSTER_LABEL): CLUSTER } },
        "status": status,
    })
}

/// A lock a run left behind, renewed `ago` before now.
fn left_lock(id: &str, activation: Option<&str>, purpose: &str) -> Value {
    let mut lock = json!({
        "holder": id,
        "hint": format!("kix deploy by {id}"),
        "purpose": purpose,
        "renewed": rfc3339(Utc::now()),
        "durationSeconds": 30,
    });
    if let Some(a) = activation {
        lock["activation"] = json!(a);
    }
    lock
}

fn status_of(api: &FakeApi) -> HeadStatus {
    serde_json::from_value(api.object(KIND, CLUSTER).unwrap()["status"].clone()).unwrap()
}

fn phase(api: &FakeApi, name: &str) -> String {
    api.object("Activation", name).unwrap()["status"]["phase"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

fn clock() -> Arc<dyn Clock> {
    Arc::new(TestClock::default())
}

/// Write a ConfigMap through `client`.
async fn write(client: &Client, name: &str) -> Result<(), kube::Error> {
    let api: Api<DynamicObject> = Api::namespaced_with(
        client.clone(),
        "default",
        &kube::discovery::ApiResource::from_gvk_with_plural(
            &kube::api::GroupVersionKind::gvk("", "v1", "ConfigMap"),
            "configmaps",
        ),
    );
    let cm: DynamicObject = serde_json::from_value(json!({
        "apiVersion": "v1", "kind": "ConfigMap",
        "metadata": { "name": name, "namespace": "default" },
    }))
    .unwrap();
    api.create(&PostParams::default(), &cm).await.map(|_| ())
}

#[tokio::test(start_paused = true)]
async fn the_first_run_creates_kixs_definitions_and_the_head() {
    let api = FakeApi::new([record("c1-old", "Active")]);
    let client = api.client();
    let lock = take(&client, request("a", Some("c1-new")), clock(), &|_| {})
        .await
        .unwrap();
    assert_eq!(api.names("CustomResourceDefinition"), {
        let mut names = crate::cluster::own_crds::all().map(|crd| crd.name).to_vec();
        names.sort();
        names
    });
    let status = status_of(&api);
    assert_eq!(
        status.current.as_deref(),
        Some("c1-old"),
        "rebuilt from phases"
    );
    assert_eq!(status.generation, 0);
    let held = status.lock.unwrap();
    assert_eq!(held.holder, "a");
    assert_eq!(held.activation.as_deref(), Some("c1-new"));
    assert_eq!(held.purpose, Purpose::Deploy);
    let obj = api.object(KIND, CLUSTER).unwrap();
    assert_eq!(
        obj["metadata"]["labels"][crate::manifest::keys::CLUSTER_LABEL],
        CLUSTER
    );
    lock.release().await.unwrap();
    let status = status_of(&api);
    assert!(status.lock.is_none());
    assert_eq!(
        status.generation, 0,
        "a run that wrote nothing raises nothing"
    );
}

#[tokio::test(start_paused = true)]
async fn a_second_run_refuses_once_the_holder_renews() {
    let api = FakeApi::new([]);
    let client = api.client();
    let first = take(&client, request("a", Some("r1")), clock(), &|_| {})
        .await
        .unwrap();
    let started = tokio::time::Instant::now();
    let Err(TakeError::Held(held)) =
        take(&client, request("b", Some("r2")), clock(), &|_| {}).await
    else {
        panic!("the second run was not refused");
    };
    assert!(started.elapsed() <= RENEW_EVERY + Duration::from_secs(2));
    assert_eq!(held.lock.holder, "a");
    let text = held.to_string();
    assert!(
        text.contains("kix deploy by a (deploy of record r1)"),
        "{text}"
    );
    assert!(
        text.contains("Nothing was changed on the cluster."),
        "{text}"
    );
    assert_eq!(status_of(&api).lock.unwrap().holder, "a");
    first.release().await.unwrap();
    take(&client, request("b", Some("r2")), clock(), &|_| {})
        .await
        .unwrap();
}

#[tokio::test(start_paused = true)]
async fn a_lock_nobody_renews_is_taken_over_after_one_lease() {
    // The dead run deployed a record that is now current: the lock is
    // cleared and nothing else changes.
    let api = FakeApi::new([
        record("cur", "Active"),
        head(
            json!({ "current": "cur", "generation": 4, "lock": left_lock("dead", Some("cur"), "deploy") }),
        ),
    ]);
    let started = tokio::time::Instant::now();
    let lock = take(&api.client(), request("b", Some("new")), clock(), &|_| {})
        .await
        .unwrap();
    assert!(started.elapsed() >= LEASE);
    assert_eq!(phase(&api, "cur"), "Active");
    let status = status_of(&api);
    assert_eq!(status.lock.unwrap().holder, "b");
    assert_eq!(status.generation, 5, "the dead run may have written");
    drop(lock);

    // The new run deploys the record the dead run deployed: it continues it.
    let api = FakeApi::new([
        record("cur", "Active"),
        record("new", "Deploying"),
        head(
            json!({ "current": "cur", "generation": 4, "lock": left_lock("dead", Some("new"), "deploy") }),
        ),
    ]);
    let _lock = take(&api.client(), request("b", Some("new")), clock(), &|_| {})
        .await
        .unwrap();
    assert_eq!(phase(&api, "new"), "Deploying");
    assert_eq!(status_of(&api).generation, 4);

    // Any other record the dead run left Deploying is marked Failed.
    let api = FakeApi::new([
        record("cur", "Active"),
        record("other", "Deploying"),
        head(
            json!({ "current": "cur", "generation": 4, "lock": left_lock("dead", Some("other"), "deploy") }),
        ),
    ]);
    let _lock = take(&api.client(), request("b", Some("new")), clock(), &|_| {})
        .await
        .unwrap();
    assert_eq!(phase(&api, "other"), "Failed");
    assert_eq!(phase(&api, "cur"), "Active");
    assert_eq!(status_of(&api).generation, 5);
}

#[tokio::test(start_paused = true)]
async fn a_holder_takes_over_its_own_lock_at_once() {
    let api = FakeApi::new([head(
        json!({ "generation": 1, "lock": left_lock("kix-operator/kix", None, "deploy") }),
    )]);
    let started = tokio::time::Instant::now();
    let _lock = take(
        &api.client(),
        request("kix-operator/kix", None),
        clock(),
        &|_| {},
    )
    .await
    .unwrap();
    assert!(started.elapsed() < Duration::from_secs(1));
}

#[tokio::test(start_paused = true)]
async fn the_holder_stops_writing_twenty_seconds_after_its_last_renewal() {
    let api = FakeApi::new([]);
    let client = api.client();
    let lock = take(&client, request("a", None), clock(), &|_| {})
        .await
        .unwrap();
    let guarded = lock.guarded(&client);
    let token = CancelToken::new();
    lock.stop_with(&token);
    write(&guarded, "before").await.unwrap();
    assert!(lock.wrote());

    // Every renewal fails from now on.
    let path = format!(
        "/apis/{}/v1alpha1/{PLURAL}/{CLUSTER}",
        crate::manifest::keys::GROUP
    );
    api.fail_next(&path, u32::MAX, 500);
    tokio::time::sleep(Duration::from_secs(15)).await;
    write(&guarded, "still-inside").await.unwrap();
    tokio::time::sleep(Duration::from_secs(6)).await;
    let err = write(&guarded, "after").await.unwrap_err();
    assert!(
        err.to_string()
            .contains("Kix stopped writing to the cluster"),
        "{err}"
    );
    assert!(token.is_cancelled());
    assert_eq!(api.names("ConfigMap"), vec!["before", "still-inside"]);
}

#[tokio::test(start_paused = true)]
async fn the_wall_clock_counts_a_sleep_the_monotonic_clock_missed() {
    let api = FakeApi::new([]);
    let client = api.client();
    let clock = Arc::new(TestClock::default());
    let lock = take(&client, request("a", None), clock.clone(), &|_| {})
        .await
        .unwrap();
    let guarded = lock.guarded(&client);
    clock.jump(Duration::from_secs(21));
    assert!(matches!(
        lock.stopped(),
        Some(WritesStopped::Deadline { .. })
    ));
    assert!(write(&guarded, "after-sleep").await.is_err());
    assert!(api.names("ConfigMap").is_empty());
    // Writes to the head pass, and a renewal lets the run write again.
    lock.renew().await.unwrap();
    write(&guarded, "renewed").await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn a_moved_generation_refuses_a_confirmed_plan() {
    let api = FakeApi::new([head(json!({ "generation": 3 }))]);
    let client = api.client();
    let mut req = request("a", None);
    req.expect = Some(2);
    let Err(err) = take(&client, req, clock(), &|_| {}).await else {
        panic!("a plan of generation 2 ran at generation 3");
    };
    assert!(
        matches!(
            err,
            TakeError::GenerationMoved {
                planned: 2,
                now: 3,
                ..
            }
        ),
        "{err}"
    );
    assert!(err.to_string().contains("Run the command again"), "{err}");
    assert!(status_of(&api).lock.is_none(), "the lock was released");

    let mut req = request("a", None);
    req.expect = Some(3);
    take(&client, req, clock(), &|_| {}).await.unwrap();

    // A plan that found no head binds to generation 0.
    let api = FakeApi::new([]);
    let mut req = request("a", None);
    req.expect = Some(0);
    take(&api.client(), req, clock(), &|_| {}).await.unwrap();
}

fn rec(name: &str, phase: &str) -> Record {
    Record {
        name: name.into(),
        phase: phase.into(),
        ..Default::default()
    }
}

fn new_lock() -> LockState {
    LockState {
        holder: "b".into(),
        hint: String::new(),
        activation: Some("next".into()),
        purpose: Purpose::Deploy,
        renewed: rfc3339(Utc::now()),
        duration_seconds: 30,
        waiting: None,
    }
}

fn written(generation: u64, current: Option<&str>) -> HeadStatus {
    HeadStatus {
        current: current.map(str::to_string),
        generation,
        lock: None,
        writer: Some(Writer {
            version: "0.10.0".into(),
            program: Program::Cli,
        }),
    }
}

#[test]
fn the_head_is_rebuilt_from_the_phases() {
    let records = [rec("x", "Active"), rec("y", "Superseded")];

    // No head, and a head with no status, as after a restore.
    for existing in [None, Some(None)] {
        let d = decide(existing, None, &records, new_lock());
        assert_eq!(d.status.current.as_deref(), Some("x"));
        assert_eq!(d.status.generation, 0);
        assert_eq!(d.status.writer, None);
        assert_eq!(d.repair, None);
    }

    // An older Kix deployed x after the head named y, and superseded y.
    let head = written(7, Some("y"));
    let d = decide(Some(Some(&head)), None, &records, new_lock());
    assert_eq!(d.status.current.as_deref(), Some("x"));
    assert_eq!(d.status.generation, 8);
    assert_eq!(d.status.writer, None, "the writer is unknown now");

    // The record the head names is gone.
    let head = written(7, Some("gone"));
    let d = decide(Some(Some(&head)), None, &records, new_lock());
    assert_eq!(d.status.current.as_deref(), Some("x"));
    assert_eq!(d.status.generation, 8);

    // No record has a current phase either: the cluster has no current
    // record.
    let d = decide(
        Some(Some(&head)),
        None,
        &[rec("y", "Superseded")],
        new_lock(),
    );
    assert_eq!(d.status.current, None);

    // An older Kix deployed x, which has no revision map, after the head
    // named y, a record this Kix deployed with a map, and left y Active.
    let mapped = Record {
        revisions: Some(Ok(crate::cluster::revision::RevisionMap {
            instances: Default::default(),
            cluster_level: "c-1".into(),
            kept_orphans: None,
        })),
        deployed_at: Some("2026-01-01T00:00:00Z".into()),
        ..rec("y", "Active")
    };
    let older = Record {
        deployed_at: Some("2026-02-01T00:00:00Z".into()),
        ..rec("x", "Active")
    };
    let head = written(7, Some("y"));
    let d = decide(
        Some(Some(&head)),
        None,
        &[older.clone(), mapped.clone()],
        new_lock(),
    );
    assert_eq!(d.status.current.as_deref(), Some("x"));
    assert_eq!(d.status.generation, 8);
    assert_eq!(d.repair, None);
    // A deploy by this Kix that stopped between its commit and its phases
    // leaves its record without a current phase, and the phases are
    // repaired from the head instead.
    let committed = Record {
        phase: "Deploying".into(),
        ..mapped
    };
    let d = decide(Some(Some(&head)), None, &[older, committed], new_lock());
    assert_eq!(d.status.current.as_deref(), Some("y"));
    assert!(d.repair.is_some());

    // The head and the phases agree: nothing changes but the lock.
    let head = written(7, Some("x"));
    let d = decide(Some(Some(&head)), None, &records, new_lock());
    assert_eq!(d.status.generation, 7);
    assert!(d.status.writer.is_some());
    assert_eq!(d.repair, None);
    assert_eq!(d.status.lock.unwrap().holder, "b");
}

#[test]
fn a_deploy_that_stopped_after_its_commit_gets_its_phases() {
    let head = written(5, Some("new"));
    let d = decide(
        Some(Some(&head)),
        None,
        &[rec("old", "Active"), rec("new", "Deploying")],
        new_lock(),
    );
    assert_eq!(
        d.repair,
        Some(lock::PhaseRepair {
            current: "new".into(),
            phase: Some("Active"),
            supersede: vec!["old".into()],
        })
    );
    assert_eq!(d.status.generation, 6);
    assert_eq!(d.status.current.as_deref(), Some("new"));

    // A run whose last checkpoint counted failures ends Degraded.
    let mut failed = rec("new", "Deploying");
    failed.waves = vec![crate::cluster::activation::WaveRecord {
        wave_index: 0,
        status: crate::cluster::activation::WaveStatus::Failed,
        resource_count: 2,
        applied: 1,
        failed: 1,
    }];
    let d = decide(Some(Some(&head)), None, &[failed], new_lock());
    assert_eq!(d.repair.unwrap().phase, Some("Degraded"));
}

#[tokio::test(start_paused = true)]
async fn taking_the_lock_repairs_the_phases_after_a_crash_between_commit_and_phases() {
    let api = FakeApi::new([
        record("old", "Active"),
        record("new", "Deploying"),
        head(json!({ "current": "new", "generation": 5 })),
    ]);
    let lock = take(&api.client(), request("b", None), clock(), &|_| {})
        .await
        .unwrap();
    assert_eq!(phase(&api, "new"), "Active");
    assert_eq!(phase(&api, "old"), "Superseded");
    assert_eq!(lock.generation(), 6);
}

#[tokio::test(start_paused = true)]
async fn a_partial_end_raises_the_generation_and_leaves_current() {
    let api = FakeApi::new([
        record("cur", "Active"),
        head(json!({ "current": "cur", "generation": 2 })),
    ]);
    let client = api.client();
    let lock = take(&client, request("b", Some("part")), clock(), &|_| {})
        .await
        .unwrap();
    write(&lock.guarded(&client), "applied").await.unwrap();
    lock.release().await.unwrap();
    let status = status_of(&api);
    assert_eq!(status.current.as_deref(), Some("cur"));
    assert_eq!(status.generation, 3);
    assert_eq!(status.writer.unwrap().program, Program::Cli);
    assert!(status.lock.is_none());
}

#[tokio::test(start_paused = true)]
async fn a_commit_is_the_one_point_a_deploy_becomes_current() {
    let api = FakeApi::new([
        record("old", "Active"),
        head(json!({ "current": "old", "generation": 2 })),
    ]);
    let client = api.client();
    let lock = take(&client, request("b", Some("new")), clock(), &|_| {})
        .await
        .unwrap();
    write(&lock.guarded(&client), "applied").await.unwrap();
    lock.commit("new").await.unwrap();
    let status = status_of(&api);
    assert_eq!(status.current.as_deref(), Some("new"));
    assert_eq!(status.generation, 3);
    assert_eq!(
        status.lock.as_ref().unwrap().holder,
        "b",
        "the lock is held until the phases are written"
    );
    lock.release().await.unwrap();
    let status = status_of(&api);
    assert_eq!(status.generation, 3, "the commit already counted the run");
    assert!(status.lock.is_none());
}

#[tokio::test(start_paused = true)]
async fn a_repair_gives_way_and_leaves_writer_and_generation() {
    let api = FakeApi::new([
        record("cur", "Active"),
        head(json!({
        "current": "cur",
        "generation": 9,
        "writer": { "version": "0.10.0", "program": "operator" },
        })),
    ]);
    let client = api.client();
    let mut repair_request = request("kix-operator/kix", Some("cur"));
    repair_request.purpose = Purpose::Repair;
    let repair = take(&client, repair_request, clock(), &|_| {})
        .await
        .unwrap();
    let repair_client = repair.guarded(&client);
    write(&repair_client, "drift").await.unwrap();
    let stop = CancelToken::new();
    repair.stop_with(&stop);

    let waiting = tokio::spawn({
        let client = client.clone();
        async move { take(&client, request("b", Some("new")), clock(), &|_| {}).await }
    });
    // The waiting run asks the repair to give way; the repair's next write
    // reads that and stops.
    while status_of(&api).lock.unwrap().waiting.is_none() {
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let err = write(&repair_client, "more-drift").await.unwrap_err();
    assert!(err.to_string().contains("gave the deploy lock"), "{err}");
    assert!(stop.is_cancelled());
    repair.release().await.unwrap();

    let lock = waiting.await.unwrap().unwrap();
    let status = status_of(&api);
    assert_eq!(status.lock.unwrap().holder, "b");
    assert_eq!(status.generation, 9, "a repair is not a write");
    assert_eq!(status.writer.unwrap().program, Program::Operator);
    assert_eq!(lock.generation(), 9);
}

#[test]
fn a_read_says_when_the_holder_has_probably_died() {
    let now = Utc::now();
    let mut lock = new_lock();
    lock.hint = "kix deploy by ana@laptop, process 7".into();
    lock.renewed = rfc3339(now - chrono::Duration::seconds(8));
    let live = LockView::of(&lock, now);
    assert!(!live.probably_dead);
    assert_eq!(
        live.describe(),
        "kix deploy by ana@laptop, process 7 holds the deploy lock (deploy of next), renewed 8s ago"
    );
    lock.renewed = rfc3339(now - chrono::Duration::seconds(95));
    let dead = LockView::of(&lock, now);
    assert!(dead.probably_dead);
    assert!(
        dead.describe().ends_with(
            "renewed 95s ago. Its 30s lease has expired, so that run has likely stopped; the next command that changes the cluster will take over the lock"
        ),
        "{}",
        dead.describe()
    );
}

/// Before a command plans, a lock another run holds is settled: a live
/// holder is refused, a dead one is taken over with its cleanup and released
/// at once, and no lock means no write. The take after the plan then finds
/// the generation the plan read.
#[tokio::test(start_paused = true)]
async fn a_held_lock_is_settled_before_the_plan() {
    let api = FakeApi::new([
        record("cur", "Active"),
        record("other", "Deploying"),
        head(
            json!({ "current": "cur", "generation": 3, "lock": left_lock("dead", Some("other"), "deploy") }),
        ),
    ]);
    let client = api.client();
    settle(&client, request("b", Some("new")), clock(), &|_| {})
        .await
        .unwrap();
    assert_eq!(phase(&api, "other"), "Failed");
    let status = status_of(&api);
    assert!(status.lock.is_none());
    assert_eq!(status.generation, 4, "the takeover counts once");
    let mut req = request("b", Some("new"));
    req.expect = Some(4);
    take(&client, req, clock(), &|_| {}).await.unwrap();

    let api = FakeApi::new([]);
    let before = api.requests().len();
    settle(&api.client(), request("b", None), clock(), &|_| {})
        .await
        .unwrap();
    assert!(
        api.requests()[before..]
            .iter()
            .all(|r| r.starts_with("GET")),
        "{:?}",
        api.requests()
    );

    let api = FakeApi::new([]);
    let client = api.client();
    let _live = take(&client, request("a", None), clock(), &|_| {})
        .await
        .unwrap();
    let err = settle(&client, request("b", None), clock(), &|_| {})
        .await
        .unwrap_err();
    assert!(matches!(err, TakeError::Held(_)), "{err}");
}
