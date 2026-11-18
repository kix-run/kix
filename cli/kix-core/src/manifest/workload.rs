//! Locate the pod spec inside a workload or Pod manifest.

use serde_json::Value;

use super::kinds::{self, GroupKind};

/// Return the pod spec inside `manifest` (`spec` for `Pod`,
/// `spec.jobTemplate.spec.template.spec` for `CronJob`, and
/// `spec.template.spec` for standard workload controllers), or `None` if the
/// kind has no pod template.
pub fn pod_spec(manifest: &Value) -> Option<&Value> {
    match GroupKind::of_manifest(manifest) {
        kinds::POD => manifest.get("spec"),
        kinds::CRON_JOB => manifest.pointer("/spec/jobTemplate/spec/template/spec"),
        kinds::DEPLOYMENT
        | kinds::STATEFUL_SET
        | kinds::DAEMON_SET
        | kinds::REPLICA_SET
        | kinds::JOB => manifest.pointer("/spec/template/spec"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn every_kind_with_a_template_is_found_and_the_rest_are_not() {
        let spec = json!({ "containers": [] });
        for kind in ["Deployment", "StatefulSet", "DaemonSet", "ReplicaSet"] {
            let m = json!({ "apiVersion": "apps/v1", "kind": kind, "spec": { "template": { "spec": spec } } });
            assert_eq!(pod_spec(&m), Some(&spec), "{kind}");
        }
        let job = json!({ "apiVersion": "batch/v1", "kind": "Job", "spec": { "template": { "spec": spec } } });
        assert_eq!(pod_spec(&job), Some(&spec));
        let cron = json!({ "apiVersion": "batch/v1", "kind": "CronJob", "spec": { "jobTemplate": { "spec": { "template": { "spec": spec } } } } });
        assert_eq!(pod_spec(&cron), Some(&spec));
        let pod = json!({ "apiVersion": "v1", "kind": "Pod", "spec": spec });
        assert_eq!(pod_spec(&pod), Some(&spec));

        assert_eq!(
            pod_spec(&json!({ "apiVersion": "v1", "kind": "Service", "spec": {} })),
            None
        );
        assert_eq!(pod_spec(&json!({ "spec": {} })), None);
        assert_eq!(
            pod_spec(&json!({ "apiVersion": "apps/v1", "kind": "Deployment" })),
            None
        );
        let other = json!({ "apiVersion": "batch.volcano.sh/v1alpha1", "kind": "Job", "spec": { "template": { "spec": spec } } });
        assert_eq!(pod_spec(&other), None);
    }
}
