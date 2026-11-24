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
        let finalizers = finalizers_of(&obj);
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
    Some(waiting_for(&finalizers_of(obj)))
}

/// Return the finalizers that hold `obj`: `metadata.finalizers`, and for a
/// Namespace also `spec.finalizers`, where Kubernetes keeps the finalizer
/// that empties the namespace.
pub fn finalizers_of(obj: &DynamicObject) -> Vec<String> {
    let mut finalizers = obj.metadata.finalizers.clone().unwrap_or_default();
    if let Some(spec) = obj
        .data
        .pointer("/spec/finalizers")
        .and_then(|f| f.as_array())
    {
        finalizers.extend(spec.iter().filter_map(|f| f.as_str()).map(str::to_string));
    }
    finalizers
}

/// Describe what an object being deleted waits for, naming each finalizer.
/// The finalizers Kubernetes owns get a few words on what holds them.
fn waiting_for(finalizers: &[String]) -> String {
    if finalizers.is_empty() {
        return "being deleted".to_string();
    }
    let named: Vec<String> = finalizers
        .iter()
        .map(|f| match kubernetes_finalizer(f) {
            Some(builtin) => format!("{f} ({})", builtin.holds),
            None => f.clone(),
        })
        .collect();
    format!("being deleted, waiting for {}", named.join(", "))
}

/// A finalizer that Kubernetes itself owns.
struct Builtin {
    /// What holds the object, in a few words.
    holds: &'static str,
    /// What to do instead of removing the finalizer, for a finalizer that
    /// guards an object still in use or waits for other objects. `None` for
    /// a finalizer that guards a cleanup, which a user may skip at a cost,
    /// as with a controller's finalizer.
    instead: Option<&'static str>,
}

/// Return the finalizer `name` when Kubernetes itself owns it, or `None`.
///
/// The names come from the Kubernetes source: `orphan` and
/// `foregroundDeletion` from `k8s.io/apimachinery` (`metav1`), the
/// Namespace's `kubernetes` from `k8s.io/api` (`core/v1`), the volume
/// protection finalizers from `pkg/controller/volume/pvcprotection` and
/// `pvprotection`, `kubernetes.io/pv-controller` from the persistent volume
/// controller, `external-provisioner.volume.kubernetes.io/finalizer` from the
/// CSI external-provisioner, `batch.kubernetes.io/job-tracking` from the Job
/// controller, and `service.kubernetes.io/load-balancer-cleanup` from the
/// cloud provider's service controller.
fn kubernetes_finalizer(name: &str) -> Option<Builtin> {
    let (holds, instead) = match name {
        "kubernetes.io/pvc-protection" => (
            "a pod still uses the claim",
            Some(
                "stop the pods that mount the claim. Do not remove this finalizer: Kubernetes \
                 would let the claim go while a pod still uses it, and with reclaim policy \
                 `Delete`, Kubernetes deletes the volume and its data",
            ),
        ),
        "kubernetes.io/pv-protection" => (
            "a claim is still bound to the volume",
            Some("delete the claim bound to the volume first"),
        ),
        "foregroundDeletion" => (
            "Kubernetes is deleting the objects it owns first",
            Some("find the objects it owns that are still being deleted and why"),
        ),
        "orphan" => (
            "Kubernetes is detaching the objects it owns first",
            Some(
                "this normally finishes in seconds; check that kube-controller-manager is running",
            ),
        ),
        "kubernetes" => (
            "Kubernetes is deleting every object in the namespace",
            Some("find the objects still in the namespace and why they are still being deleted"),
        ),
        "batch.kubernetes.io/job-tracking" => (
            "the Job controller is still counting this pod",
            Some("check that kube-controller-manager is running"),
        ),
        "service.kubernetes.io/load-balancer-cleanup" => {
            ("Kubernetes is removing the cloud load balancer", None)
        }
        "kubernetes.io/pv-controller" => {
            ("Kubernetes is deleting the storage volume behind it", None)
        }
        "external-provisioner.volume.kubernetes.io/finalizer" => {
            ("the storage driver is deleting the volume behind it", None)
        }
        _ => return None,
    };
    Some(Builtin { holds, instead })
}

/// Who runs a delete, which decides what a message tells its reader to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Runner {
    /// A person, through `kix deploy`, `kix rollback`, or `kix gc`.
    Cli,
    /// The Kix operator.
    Operator,
}

/// The path that deleted an object, which decides what Kix did around a
/// delete that did not finish and what the reader can do next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeletePath {
    /// A deploy's or rollback's prune.
    Prune(Runner),
    /// `kix gc`, with or without `--full-scan`.
    Gc,
    /// The Kix operator's teardown of a deleted Activation.
    Teardown,
    /// The delete before Kix creates an object again (an immutable field
    /// changed, or a Job runs again).
    Recreate(Runner),
    /// An object of the build that was already being deleted when Kix
    /// came to apply it.
    Apply(Runner),
}

/// Return the message for one object whose delete did not finish within the
/// wait: what it waits for and how long Kix waited, what to do about each
/// finalizer Kubernetes uses to guard an object, and, when every finalizer
/// left guards only a cleanup, the `kubectl` command that removes them.
/// [`stuck_explanation`] says the rest once per run.
pub fn stuck_message(rid: &ResourceId, stuck: &Stuck) -> String {
    let secs = stuck.elapsed.as_secs();
    if stuck.finalizers.is_empty() {
        return format!(
            "[{STUCK_DELETE_ID}] {rid} is still being deleted after {secs}s with no \
             finalizers left; Kubernetes normally removes it within seconds."
        );
    }
    let named: Vec<String> = stuck
        .finalizers
        .iter()
        .map(|f| match kubernetes_finalizer(f) {
            Some(builtin) => format!("{f} ({})", builtin.holds),
            None => f.clone(),
        })
        .collect();
    let mut message = format!(
        "[{STUCK_DELETE_ID}] {rid} is still being deleted after {secs}s, waiting for {}.",
        named.join(", ")
    );
    let guards: Vec<(&String, &'static str)> = stuck
        .finalizers
        .iter()
        .filter_map(|f| Some((f, kubernetes_finalizer(f)?.instead?)))
        .collect();
    for (finalizer, instead) in &guards {
        message.push_str(&format!("\n  {finalizer}: {instead}."));
    }
    if guards.is_empty() {
        message.push_str(&format!(
            "\n  To skip cleanup and delete it at once (anything outside the object stays): {}",
            remove_finalizers_command(rid)
        ));
    }
    message
}

/// Return the explanation that goes once with the [`stuck_message`]s of a
/// run on `path`: that the deletes may still finish, what to run next, what
/// Kix kept, and what removing a finalizer by hand gives up.
pub fn stuck_explanation(path: DeletePath) -> String {
    let recorded = "Kix did not delete any object that the build records as a dependency of \
                    the objects above (a custom resource records a dependency on its operator \
                    only when its package declares that link; most do not yet); kept objects \
                    stay recorded, and";
    let cli_retry = "Run the same command again later, or pass a longer `--timeout` (default 3 \
                     minutes without a finalizer being removed, or 5 minutes in total for each \
                     object).";
    let operator_retry = "The Kix operator will try again on its next reconcile (it waits up \
                          to 300 seconds without a finalizer being removed, or 5 minutes in \
                          total for each object).";
    let recreated = "Kix deleted each object above to create it again because an immutable \
                     field changed or a Job must run again; Kix held no other objects back and \
                     has not created the new object yet, and";
    let already = "This object was already being deleted on the cluster, so Kix waited for \
                   deletion to finish and has not created the new object yet.";
    let (retry, did) = match path {
        DeletePath::Prune(Runner::Cli) => (
            cli_retry.to_string(),
            format!(
                "{recorded} the next `kix deploy --prune` or `kix gc` will delete them once \
                 the objects above are gone."
            ),
        ),
        DeletePath::Prune(Runner::Operator) => (
            operator_retry.to_string(),
            format!(
                "{recorded} the Kix operator will delete them once the objects above are gone."
            ),
        ),
        DeletePath::Gc => (
            "Run `kix gc` again later (Kix waits up to 3 minutes without a finalizer being \
             removed, or 5 minutes in total for each object)."
                .to_string(),
            format!(
                "{recorded} the next `kix gc` will delete them once the objects above are gone."
            ),
        ),
        DeletePath::Teardown => (
            "The Kix operator keeps the deleted Activation (its deployment record) and will try \
             again 30 seconds after each attempt ends (it waits up to 300 seconds without a \
             finalizer being removed, or 5 minutes in total for each object)."
                .to_string(),
            format!(
                "{recorded} the Kix operator will delete them once the objects above are gone."
            ),
        ),
        DeletePath::Recreate(Runner::Cli) => (
            cli_retry.to_string(),
            format!(
                "{recreated} rerunning the command will create it once the old object is gone."
            ),
        ),
        DeletePath::Recreate(Runner::Operator) => (
            operator_retry.to_string(),
            format!(
                "{recreated} the Kix operator will create it on its next reconcile once the old \
                 object is gone."
            ),
        ),
        DeletePath::Apply(Runner::Cli) => (
            cli_retry.to_string(),
            format!("{already} Once the old object is gone, run the command again to create it."),
        ),
        DeletePath::Apply(Runner::Operator) => (
            operator_retry.to_string(),
            format!(
                "{already} Once the old object is gone, the Kix operator will create it on its \
                 next reconcile."
            ),
        ),
    };
    format!(
        "Kix stopped waiting, but these deletes may still finish: slow cleanups, such as \
         removing a cloud load balancer or deleting a storage volume, can take longer. \
         {retry}\n\n{did}\n\nKix never removes a finalizer itself. A controller that added a \
         finalizer removes it when its cleanup finishes; check that the controller is \
         running. Removing a finalizer yourself with the command shown makes Kubernetes \
         delete the object at once, and whatever the finalizer would have cleaned up outside \
         the object, such as a database or a cloud resource, stays. Kix prints no removal \
         command when an object has a finalizer that Kubernetes uses to guard an object still \
         in use or wait for other objects, even beside a controller finalizer, because the \
         command would remove both."
    )
}

/// Return why `path` kept `rid`: `holder`, which depends on it, is still on
/// the cluster. `shared` says that `holder` stays because another Kix cluster
/// still deploys it.
pub fn held_back_reason(
    rid: &ResourceId,
    holder: &ResourceId,
    path: DeletePath,
    shared: bool,
) -> String {
    if shared {
        return format!(
            "kept {rid} because {holder} depends on it and is still deployed by another Kix cluster"
        );
    }
    let next = match path {
        DeletePath::Gc => "the next `kix gc`",
        DeletePath::Teardown
        | DeletePath::Prune(Runner::Operator)
        | DeletePath::Recreate(Runner::Operator)
        | DeletePath::Apply(Runner::Operator) => "the Kix operator",
        DeletePath::Prune(Runner::Cli)
        | DeletePath::Recreate(Runner::Cli)
        | DeletePath::Apply(Runner::Cli) => "the next `kix deploy --prune` or `kix gc`",
    };
    format!(
        "kept {rid} because {holder} depends on it and is still on the cluster; {rid} stays \
         recorded, and {next} will delete {rid} once {holder} is gone"
    )
}

/// Return why `rid` was kept: it is part of a dependency cycle, or depends
/// on one, so no order deletes it after everything that needs it.
pub fn cycle_reason(rid: &ResourceId) -> String {
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
        let fake = FakeApi::new([config_map(&["example.com/hold"])]);
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
        let fake = FakeApi::new([config_map(&["example.com/hold"])]);
        let api = api_for(&fake).await;
        let uid = uid_of(&fake);
        api.delete("cm", &Default::default()).await.unwrap();
        fake.remove_finalizers("ConfigMap", "cm");
        fake.insert(config_map(&["example.com/hold"]));
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
        let fake = FakeApi::new([config_map(&["example.com/hold"])]);
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
        assert_eq!(stuck.finalizers, vec!["example.com/hold".to_string()]);
        assert!(stuck.elapsed >= Duration::from_secs(10), "{stuck:?}");
        assert!(stuck.elapsed < Duration::from_secs(13), "{stuck:?}");
        assert_eq!(
            seen.last().unwrap(),
            "being deleted, waiting for example.com/hold"
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
        let fake = FakeApi::new([config_map(&["example.com/hold"])]);
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
        let fake = FakeApi::new([config_map(&["example.com/hold"])]);
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

    fn stuck(finalizers: &[&str]) -> Stuck {
        Stuck {
            elapsed: Duration::from_secs(180),
            finalizers: finalizers.iter().map(|f| f.to_string()).collect(),
        }
    }

    /// A controller's finalizer gets the command that removes it, with the
    /// record id and the time waited.
    #[test]
    fn a_controller_finalizer_gets_the_kubectl_command() {
        let rid = ResourceId::new("keda.sh", "ScaledObject", "app", "worker");
        let message = stuck_message(&rid, &stuck(&["finalizer.keda.sh"]));
        assert!(message.starts_with("[K2794] "), "{message}");
        assert!(message.contains("finalizer.keda.sh"), "{message}");
        assert!(message.contains("180s"), "{message}");
        assert!(
            message.contains(
                r#"kubectl -n app patch scaledobject.keda.sh worker --type=merge -p '{"metadata":{"finalizers":null}}'"#
            ),
            "{message}"
        );
        let ns = ResourceId::new("", "Namespace", CLUSTER_SCOPED, "old");
        assert_eq!(
            remove_finalizers_command(&ns),
            r#"kubectl patch namespace old --type=merge -p '{"metadata":{"finalizers":null}}'"#
        );
    }

    /// A claim held by `pvc-protection` says a pod still uses it and what to
    /// do, and offers no command that removes the finalizer, also when a
    /// controller's finalizer sits beside it.
    #[test]
    fn a_protection_finalizer_gets_no_kubectl_command() {
        let rid = ResourceId::new("", "PersistentVolumeClaim", "app", "data");
        for finalizers in [
            &["kubernetes.io/pvc-protection"][..],
            &["kubernetes.io/pvc-protection", "example.com/backup"][..],
        ] {
            let message = stuck_message(&rid, &stuck(finalizers));
            assert!(message.contains("a pod still uses the claim"), "{message}");
            assert!(
                message.contains("stop the pods that mount the claim"),
                "{message}"
            );
            assert!(!message.contains("kubectl"), "{message}");
        }
        for name in [
            "foregroundDeletion",
            "orphan",
            "kubernetes.io/pv-protection",
        ] {
            let message = stuck_message(&rid, &stuck(&[name]));
            assert!(!message.contains("kubectl"), "{name}: {message}");
        }
        // A cleanup Kubernetes runs may be skipped at a cost, as a
        // controller's may.
        let lb = ResourceId::new("", "Service", "app", "web");
        let message = stuck_message(
            &lb,
            &stuck(&["service.kubernetes.io/load-balancer-cleanup"]),
        );
        assert!(message.contains("cloud load balancer"), "{message}");
        assert!(message.contains("kubectl"), "{message}");
    }

    /// A Namespace keeps its emptying finalizer in `spec.finalizers`, so the
    /// reason names it rather than "no finalizers left".
    #[test]
    fn a_namespace_being_emptied_names_its_spec_finalizer() {
        let ns: DynamicObject = serde_json::from_value(json!({
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": { "name": "old", "deletionTimestamp": "2026-11-24T15:54:00Z" },
            "spec": { "finalizers": ["kubernetes"] },
        }))
        .unwrap();
        assert_eq!(
            deletion_reason(&ns).unwrap(),
            "being deleted, waiting for kubernetes (Kubernetes is deleting every object in the namespace)"
        );
        assert_eq!(finalizers_of(&ns), vec!["kubernetes".to_string()]);
    }

    /// Each path's explanation says what is true for it: prune and gc keep
    /// what the objects need and name what tries again; the operator never
    /// tells its reader to run a command or pass a flag; the recreate and apply
    /// paths keep nothing. Each says the deletes may still finish.
    #[test]
    fn each_path_gets_its_own_explanation() {
        let all = [
            DeletePath::Prune(Runner::Cli),
            DeletePath::Prune(Runner::Operator),
            DeletePath::Gc,
            DeletePath::Teardown,
            DeletePath::Recreate(Runner::Cli),
            DeletePath::Recreate(Runner::Operator),
            DeletePath::Apply(Runner::Cli),
            DeletePath::Apply(Runner::Operator),
        ];
        for path in all {
            assert!(
                stuck_explanation(path).contains("may still finish"),
                "{path:?}"
            );
        }
        let cli = stuck_explanation(DeletePath::Prune(Runner::Cli));
        assert!(cli.contains("`kix deploy --prune` or `kix gc`"), "{cli}");
        assert!(cli.contains("`--timeout`"), "{cli}");
        assert!(cli.contains("most do not yet"), "{cli}");
        for path in [
            DeletePath::Prune(Runner::Operator),
            DeletePath::Teardown,
            DeletePath::Recreate(Runner::Operator),
            DeletePath::Apply(Runner::Operator),
        ] {
            let text = stuck_explanation(path);
            assert!(!text.contains("--timeout"), "{path:?}: {text}");
            assert!(!text.contains("same command"), "{path:?}: {text}");
        }
        assert!(!stuck_explanation(DeletePath::Gc).contains("--timeout"));
        let recreate = stuck_explanation(DeletePath::Recreate(Runner::Cli));
        assert!(
            recreate.contains("has not created the new object"),
            "{recreate}"
        );
        assert!(!recreate.contains("depending on"), "{recreate}");
        let apply = stuck_explanation(DeletePath::Apply(Runner::Cli));
        assert!(apply.contains("already being deleted"), "{apply}");
        assert!(!apply.contains("depending on"), "{apply}");
    }
}
