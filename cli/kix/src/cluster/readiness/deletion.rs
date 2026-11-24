//! When a deleted object is gone.
//!
//! Kubernetes deletes an object in two steps. The delete request sets
//! `metadata.deletionTimestamp`, and the object stays until every entry in
//! `metadata.finalizers` is removed, usually by the controller that added it
//! once its cleanup is done. [`wait_gone`] decides when a deletion is done.
//! Every path that deletes an object of a build calls it: deploy's prune,
//! `kix gc`, the operator's teardown, the delete before an in-place
//! recreate, and an apply onto an object that is already being deleted.
//! `kix migrate domain` waits for the retired CustomResourceDefinitions it
//! deletes by name through its own retry loop instead: it is a one-off
//! layer that is removed once no cluster needs it, and it tests its steps
//! through its own fake.
//! [`deletion_reason`] is the readiness rule for an object that is being
//! deleted: it is never ready, because it will soon be gone.

use std::time::Duration;

use kube::api::{Api, DynamicObject};
use tokio::time::Instant;

use super::super::cancel::CancelToken;
use super::{HARD_CEILING, POLL_INTERVAL};
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

/// The id of the change record for a delete that does not finish. Every
/// message that reports one starts with it.
pub const STUCK_DELETE_ID: &str = "K2794";

/// The first wait between two reads of a deleted object. It doubles up to
/// [`POLL_INTERVAL`], so a finalizer that clears in a few milliseconds costs
/// one short wait.
const FIRST_POLL: Duration = Duration::from_millis(100);

/// How a wait for a deleted object ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Deletion {
    /// The object is gone, or an object with the same name and another uid
    /// has replaced it.
    Gone,
    /// The object was still being deleted when the budget ran out.
    Stuck(Stuck),
    /// The cancel token fired.
    Cancelled,
}

/// A deleted object still on the cluster when [`wait_gone`] gave up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stuck {
    pub elapsed: Duration,
    /// The finalizers still on the object.
    pub finalizers: Vec<String>,
}

/// Wait until the object `name` with uid `uid` is gone.
///
/// The object counts as gone when a read finds nothing, or finds an object
/// with another uid. Without a `uid`, any object of that name counts as still
/// there. A failed read is returned as an error and never counts as gone.
///
/// `budget` is how long the wait may go without progress, where progress is
/// the object losing a finalizer. [`HARD_CEILING`] bounds the whole wait.
/// `on_status` gets a short description of what the object waits for after
/// every read that finds it.
pub(crate) async fn wait_gone(
    api: &Api<DynamicObject>,
    name: &str,
    uid: Option<&str>,
    budget: Duration,
    cancel: &CancelToken,
    mut on_status: impl FnMut(&str),
) -> Result<Deletion, kube::Error> {
    let start = Instant::now();
    let mut last_progress = start;
    let mut held: Option<usize> = None;
    let mut delay = FIRST_POLL;
    loop {
        if cancel.is_cancelled() {
            return Ok(Deletion::Cancelled);
        }
        let obj = match api.get_opt(name).await? {
            None => return Ok(Deletion::Gone),
            Some(obj) if uid.is_some() && obj.metadata.uid.as_deref() != uid => {
                return Ok(Deletion::Gone);
            }
            Some(obj) => obj,
        };
        let finalizers = obj.metadata.finalizers.clone().unwrap_or_default();
        if held.is_some_and(|before| finalizers.len() < before) {
            last_progress = Instant::now();
        }
        held = Some(finalizers.len());
        on_status(&waiting_for(&finalizers));
        if last_progress.elapsed() >= budget || start.elapsed() >= HARD_CEILING {
            return Ok(Deletion::Stuck(Stuck {
                elapsed: start.elapsed(),
                finalizers,
            }));
        }
        tokio::select! {
            _ = tokio::time::sleep(delay) => {}
            _ = cancel.cancelled() => return Ok(Deletion::Cancelled),
        }
        delay = (delay * 2).min(POLL_INTERVAL);
    }
}

/// Return why `obj` is not ready when it is being deleted, or `None` when it
/// is not.
pub fn deletion_reason(obj: &DynamicObject) -> Option<String> {
    obj.metadata.deletion_timestamp.as_ref()?;
    let finalizers = obj.metadata.finalizers.as_deref().unwrap_or_default();
    Some(waiting_for(finalizers))
}

/// Describe what an object being deleted waits for, naming each finalizer.
/// Kubernetes defines a few finalizers itself, and those get a few words on
/// what holds them.
fn waiting_for(finalizers: &[String]) -> String {
    if finalizers.is_empty() {
        return "being deleted".to_string();
    }
    let named: Vec<String> = finalizers
        .iter()
        .map(|f| match kubernetes_finalizer(f) {
            Some(why) => format!("{f} ({why})"),
            None => f.clone(),
        })
        .collect();
    format!("being deleted, waiting for {}", named.join(", "))
}

/// Return what holds a finalizer that Kubernetes itself defines, or `None`
/// for any other finalizer.
fn kubernetes_finalizer(finalizer: &str) -> Option<&'static str> {
    Some(match finalizer {
        "kubernetes.io/pvc-protection" => "a pod still uses the claim",
        "kubernetes.io/pv-protection" => "a claim is still bound to the volume",
        "foregroundDeletion" => "Kubernetes deletes owned objects first",
        "orphan" => "Kubernetes detaches owned objects before deleting this object",
        _ => return None,
    })
}

/// The path that deleted an object, which decides what Kix did around a
/// delete that did not finish and what the user can do next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeletePath {
    /// `kix deploy --prune` or `kix rollback --prune`.
    Prune,
    /// `kix gc`, with or without `--full-scan`.
    Gc,
    /// The Kix operator's teardown of a deleted Activation.
    Operator,
    /// The delete before Kix creates an object again (an immutable field
    /// changed, or a Job runs again).
    Recreate,
    /// An object of the build that was already being deleted when Kix
    /// came to apply it.
    Apply,
}

/// Return the message for an object whose delete did not finish within the
/// wait: what it waits for, how long Kix waited, that it may still finish,
/// what Kix did on `path`, what to do next, and the `kubectl` command that
/// removes its finalizers, with what running it gives up.
pub fn stuck_message(rid: &ResourceId, stuck: &Stuck, path: DeletePath) -> String {
    let waits = match stuck.finalizers.as_slice() {
        [] => "with no finalizers left, so Kubernetes should remove it soon".to_string(),
        [one] => format!("waiting for finalizer {one}"),
        many => format!("waiting for finalizers {}", many.join(", ")),
    };
    let secs = stuck.elapsed.as_secs();
    let recorded = format!(
        "Kix did not delete any objects that the build records {rid} as depending on (a \
         custom resource records a dependency on its operator only when its package \
         declares that link, and most do not yet); those objects stay recorded, and"
    );
    let (retry, did) = match path {
        DeletePath::Prune => (
            format!("Run the same command again once {rid} is gone, or pass a longer `--timeout`."),
            format!(
                "{recorded} the next `kix deploy --prune` or `kix gc` will delete them once \
                 {rid} is gone."
            ),
        ),
        DeletePath::Gc => (
            format!("Run `kix gc` again once {rid} is gone."),
            format!("{recorded} the next `kix gc` will delete them once {rid} is gone."),
        ),
        DeletePath::Operator => (
            format!(
                "Wait for {rid} to finish deleting; the Kix operator keeps the deleted \
                 Activation (deployment record) and tries again on its own every 30 seconds."
            ),
            format!("{recorded} the Kix operator will delete them once {rid} is gone."),
        ),
        DeletePath::Recreate => (
            format!("Run the same command again once {rid} is gone, or pass a longer `--timeout`."),
            format!(
                "Kix deleted {rid} to recreate it (because an immutable field changed or a Job \
                 must run again), held no other objects back, and has not created the new \
                 {rid} yet."
            ),
        ),
        DeletePath::Apply => (
            format!("Run the same command again once {rid} is gone, or pass a longer `--timeout`."),
            format!(
                "{rid} was already being deleted when Kix came to apply it; Kix waited for the \
                 delete to finish so it could create {rid}, and Kix has not applied {rid} yet."
            ),
        ),
    };
    let mut message = format!(
        "[{STUCK_DELETE_ID}] {rid} is still being deleted after {secs}s, {waits}.\n\
         Kix stopped waiting, but {rid} may still finish deleting: slow cleanups, such as \
         pods with a long shutdown grace period or a cloud load balancer being removed, \
         can take longer. {retry}\n{did}"
    );
    if !stuck.finalizers.is_empty() {
        message.push_str(&format!(
            "\nKubernetes keeps {rid} until every finalizer on it is removed, usually by the \
             controller that added the finalizer, after its cleanup; check that the \
             controller is running.\n\nIf you want to skip that cleanup, remove the \
             finalizers on {rid} yourself (Kix never removes a finalizer):\n  {}\nRunning \
             that command makes Kubernetes delete {rid} at once, and whatever the \
             finalizer would have cleaned up outside {rid}, such as a database or a cloud \
             resource, stays.",
            remove_finalizers_command(rid)
        ));
    }
    message
}

/// Return why `path` kept `rid`: `stuck`, which depends on it, was still
/// being deleted when the wait ended.
pub fn held_back_reason(rid: &ResourceId, stuck: &ResourceId, path: DeletePath) -> String {
    let next = match path {
        DeletePath::Gc => "the next `kix gc`",
        DeletePath::Operator => "the operator's next attempt",
        _ => "the next `kix deploy --prune` or `kix gc`",
    };
    format!(
        "kept {rid} on the cluster because {stuck} depends on it and is still being deleted; \
         {rid} stays recorded, and {next} will delete {rid} once {stuck} is gone"
    )
}

/// Return why `path` kept `rid`: it is part of a dependency cycle, or depends
/// on one, so no order deletes it after everything that needs it.
pub fn cycle_reason(rid: &ResourceId, path: DeletePath) -> String {
    let _ = path;
    format!(
        "did not delete {rid} (and kept {rid} recorded) because its recorded dependencies \
         form a cycle or an object in a cycle depends on {rid}, so Kix cannot tell which \
         object to delete first; delete {rid} with kubectl"
    )
}

/// Return the `kubectl patch` command that removes every finalizer from `rid`.
fn remove_finalizers_command(rid: &ResourceId) -> String {
    let kind = rid.kind.to_lowercase();
    let resource = if rid.group.is_empty() {
        kind
    } else {
        format!("{kind}.{}", rid.group)
    };
    let namespace = if rid.namespace == CLUSTER_SCOPED {
        String::new()
    } else {
        format!("-n {} ", rid.namespace)
    };
    format!(
        "kubectl {namespace}patch {resource} {} --type=merge -p '{{\"metadata\":{{\"finalizers\":null}}}}'",
        rid.name
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::discovery;
    use crate::cluster::fake_api::FakeApi;
    use serde_json::{Value, json};

    fn config_map(finalizers: &[&str]) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": { "name": "cm", "namespace": "app", "finalizers": finalizers },
        })
    }

    async fn api_for(fake: &FakeApi) -> Api<DynamicObject> {
        let client = fake.client();
        let d = discovery::discover_resources(&client).await.unwrap();
        let (ar, scope) = discovery::find(&d, "", "ConfigMap").unwrap();
        let rid = ResourceId::new("", "ConfigMap", "app", "cm");
        discovery::api_for(&client, ar, scope, &rid)
    }

    fn uid_of(fake: &FakeApi) -> String {
        fake.object("ConfigMap", "cm").unwrap()["metadata"]["uid"]
            .as_str()
            .unwrap()
            .to_string()
    }

    async fn wait(api: &Api<DynamicObject>, uid: Option<&str>, budget: Duration) -> Deletion {
        wait_gone(api, "cm", uid, budget, &CancelToken::new(), |_| {})
            .await
            .unwrap()
    }

    /// An object without finalizers is gone after its delete, at the first
    /// read.
    #[tokio::test(start_paused = true)]
    async fn an_object_without_finalizers_is_gone_at_once() {
        let fake = FakeApi::new([config_map(&[])]);
        let api = api_for(&fake).await;
        let uid = uid_of(&fake);
        api.delete("cm", &Default::default()).await.unwrap();
        let start = Instant::now();
        assert_eq!(
            wait(&api, Some(&uid), Duration::from_secs(10)).await,
            Deletion::Gone
        );
        assert_eq!(start.elapsed(), Duration::ZERO);
    }

    /// An object whose last finalizer is removed during the wait is gone.
    #[tokio::test(start_paused = true)]
    async fn an_object_is_gone_once_its_finalizer_is_removed() {
        let fake = FakeApi::new([config_map(&["test.kix.run/hold"])]);
        let api = api_for(&fake).await;
        let uid = uid_of(&fake);
        api.delete("cm", &Default::default()).await.unwrap();
        let remover = {
            let fake = fake.clone();
            async move {
                tokio::time::sleep(Duration::from_secs(3)).await;
                fake.remove_finalizers("ConfigMap", "cm");
            }
        };
        let (deletion, ()) = tokio::join!(wait(&api, Some(&uid), Duration::from_secs(10)), remover);
        assert_eq!(deletion, Deletion::Gone);
    }

    /// An object of the same name with another uid replaced the deleted one,
    /// so the deleted one is gone.
    #[tokio::test(start_paused = true)]
    async fn an_object_replaced_by_a_new_uid_is_gone() {
        let fake = FakeApi::new([config_map(&["test.kix.run/hold"])]);
        let api = api_for(&fake).await;
        let uid = uid_of(&fake);
        api.delete("cm", &Default::default()).await.unwrap();
        fake.remove_finalizers("ConfigMap", "cm");
        fake.insert(config_map(&["test.kix.run/hold"]));
        assert_ne!(uid_of(&fake), uid);
        assert_eq!(
            wait(&api, Some(&uid), Duration::from_secs(10)).await,
            Deletion::Gone
        );
        // Without a uid, the new object counts as the old one still there.
        assert!(matches!(
            wait(&api, None, Duration::from_secs(10)).await,
            Deletion::Stuck(_)
        ));
    }

    /// An object that keeps its finalizer is stuck once the budget passes
    /// without progress, and the result names the finalizer.
    #[tokio::test(start_paused = true)]
    async fn an_object_that_keeps_its_finalizer_is_stuck_after_the_budget() {
        let fake = FakeApi::new([config_map(&["test.kix.run/hold"])]);
        let api = api_for(&fake).await;
        let uid = uid_of(&fake);
        api.delete("cm", &Default::default()).await.unwrap();
        let mut seen = Vec::new();
        let deletion = wait_gone(
            &api,
            "cm",
            Some(&uid),
            Duration::from_secs(10),
            &CancelToken::new(),
            |s| seen.push(s.to_string()),
        )
        .await
        .unwrap();
        let Deletion::Stuck(stuck) = deletion else {
            panic!("expected stuck, got {deletion:?}");
        };
        assert_eq!(stuck.finalizers, vec!["test.kix.run/hold".to_string()]);
        assert!(stuck.elapsed >= Duration::from_secs(10), "{stuck:?}");
        assert!(stuck.elapsed < Duration::from_secs(13), "{stuck:?}");
        assert_eq!(
            seen.last().unwrap(),
            "being deleted, waiting for test.kix.run/hold"
        );
        assert_eq!(fake.names("ConfigMap"), vec!["cm"]);
    }

    /// Losing one of two finalizers is progress, so the budget starts again.
    #[tokio::test(start_paused = true)]
    async fn losing_a_finalizer_restarts_the_budget() {
        let fake = FakeApi::new([config_map(&["a.example/one", "b.example/two"])]);
        let api = api_for(&fake).await;
        let uid = uid_of(&fake);
        api.delete("cm", &Default::default()).await.unwrap();
        let remover = {
            let fake = fake.clone();
            async move {
                tokio::time::sleep(Duration::from_secs(8)).await;
                fake.patch_object("ConfigMap", "cm", |o| {
                    o["metadata"]["finalizers"] = json!(["b.example/two"]);
                });
            }
        };
        let (deletion, ()) = tokio::join!(wait(&api, Some(&uid), Duration::from_secs(10)), remover);
        let Deletion::Stuck(stuck) = deletion else {
            panic!("expected stuck, got {deletion:?}");
        };
        assert!(stuck.elapsed >= Duration::from_secs(18), "{stuck:?}");
        assert_eq!(stuck.finalizers, vec!["b.example/two".to_string()]);
    }

    /// A failed read is an error, never "gone".
    #[tokio::test(start_paused = true)]
    async fn a_read_error_is_not_gone() {
        let fake = FakeApi::new([config_map(&["test.kix.run/hold"])]);
        let api = api_for(&fake).await;
        let uid = uid_of(&fake);
        api.delete("cm", &Default::default()).await.unwrap();
        fake.fail_next("/api/v1/namespaces/app/configmaps/cm", 1, 500);
        let result = wait_gone(
            &api,
            "cm",
            Some(&uid),
            Duration::from_secs(10),
            &CancelToken::new(),
            |_| {},
        )
        .await;
        assert!(result.is_err(), "{result:?}");
    }

    /// The wait ends when the cancel token fires.
    #[tokio::test(start_paused = true)]
    async fn a_cancelled_wait_says_so() {
        let fake = FakeApi::new([config_map(&["test.kix.run/hold"])]);
        let api = api_for(&fake).await;
        api.delete("cm", &Default::default()).await.unwrap();
        let cancel = CancelToken::new();
        let canceller = {
            let cancel = cancel.clone();
            async move {
                tokio::time::sleep(Duration::from_secs(2)).await;
                cancel.cancel();
            }
        };
        let waited = wait_gone(&api, "cm", None, Duration::from_secs(60), &cancel, |_| {});
        let (deletion, ()) = tokio::join!(waited, canceller);
        assert_eq!(deletion.unwrap(), Deletion::Cancelled);
    }

    /// The reason names Kubernetes' own finalizers with what holds them.
    #[test]
    fn the_reason_explains_kubernetes_finalizers() {
        let obj: DynamicObject = serde_json::from_value(json!({
            "apiVersion": "v1",
            "kind": "PersistentVolumeClaim",
            "metadata": {
                "name": "data",
                "deletionTimestamp": "2026-11-24T15:54:00Z",
                "finalizers": ["kubernetes.io/pvc-protection"],
            },
        }))
        .unwrap();
        assert_eq!(
            deletion_reason(&obj).unwrap(),
            "being deleted, waiting for kubernetes.io/pvc-protection (a pod still uses the claim)"
        );
        let live: DynamicObject = serde_json::from_value(json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": { "name": "cm", "finalizers": ["x.example/y"] },
        }))
        .unwrap();
        assert_eq!(deletion_reason(&live), None);
    }

    /// The message carries the record id, the finalizer, the wait, and the
    /// command that removes the finalizer.
    #[test]
    fn the_stuck_message_prints_the_kubectl_command() {
        let rid = ResourceId::new("keda.sh", "ScaledObject", "app", "worker");
        let message = stuck_message(
            &rid,
            &Stuck {
                elapsed: Duration::from_secs(180),
                finalizers: vec!["finalizer.keda.sh".into()],
            },
            DeletePath::Prune,
        );
        assert!(message.starts_with("[K2794] "), "{message}");
        assert!(message.contains("finalizer.keda.sh"), "{message}");
        assert!(message.contains("180s"), "{message}");
        assert!(
            message.contains(
                r#"kubectl -n app patch scaledobject.keda.sh worker --type=merge -p '{"metadata":{"finalizers":null}}'"#
            ),
            "{message}"
        );
        let crole = ResourceId::new("", "Namespace", CLUSTER_SCOPED, "old");
        assert_eq!(
            remove_finalizers_command(&crole),
            r#"kubectl patch namespace old --type=merge -p '{"metadata":{"finalizers":null}}'"#
        );
    }

    /// Each path says what is true for it: prune and gc keep what the object
    /// needs and name the command that tries again; the recreate and apply
    /// paths keep nothing and say the new object was not created. Every
    /// message says Kix stopped waiting and the delete may still finish.
    #[test]
    fn each_path_gets_its_own_next_step() {
        let rid = ResourceId::new("", "PersistentVolumeClaim", "app", "data");
        let stuck = Stuck {
            elapsed: Duration::from_secs(180),
            finalizers: vec!["kubernetes.io/pvc-protection".into()],
        };
        let message = |path| stuck_message(&rid, &stuck, path);
        for path in [
            DeletePath::Prune,
            DeletePath::Gc,
            DeletePath::Operator,
            DeletePath::Recreate,
            DeletePath::Apply,
        ] {
            let m = message(path);
            assert!(m.starts_with("[K2794] "), "{m}");
            assert!(m.contains("180s"), "{m}");
            assert!(m.contains("may still finish"), "{m}");
        }
        assert!(message(DeletePath::Prune).contains("`kix deploy --prune` or `kix gc`"));
        assert!(message(DeletePath::Prune).contains("most do not yet"));
        assert!(message(DeletePath::Prune).contains("`--timeout`"));
        assert!(!message(DeletePath::Gc).contains("--timeout"));
        let recreate = message(DeletePath::Recreate);
        assert!(recreate.contains("has not created the new"), "{recreate}");
        assert!(!recreate.contains("depending on"), "{recreate}");
        assert!(!message(DeletePath::Apply).contains("depending on"));
    }
}
