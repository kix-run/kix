//! Locate the pod spec inside a workload or Pod manifest.

use serde_json::Value;

/// Return the pod spec inside `manifest` (`spec` for `Pod`,
/// `spec.jobTemplate.spec.template.spec` for `CronJob`, and
/// `spec.template.spec` for standard workload controllers), or `None` if the
/// kind has no pod template.
pub fn pod_spec(manifest: &Value) -> Option<&Value> {
    match manifest.get("kind").and_then(Value::as_str)? {
        "Pod" => manifest.get("spec"),
        "CronJob" => manifest.pointer("/spec/jobTemplate/spec/template/spec"),
        "Deployment" | "StatefulSet" | "DaemonSet" | "ReplicaSet" | "Job" => {
            manifest.pointer("/spec/template/spec")
        }
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
        for kind in [
            "Deployment",
            "StatefulSet",
            "DaemonSet",
            "ReplicaSet",
            "Job",
        ] {
            let m = json!({ "kind": kind, "spec": { "template": { "spec": spec } } });
            assert_eq!(pod_spec(&m), Some(&spec), "{kind}");
        }
        let cron = json!({ "kind": "CronJob", "spec": { "jobTemplate": { "spec": { "template": { "spec": spec } } } } });
        assert_eq!(pod_spec(&cron), Some(&spec));
        let pod = json!({ "kind": "Pod", "spec": spec });
        assert_eq!(pod_spec(&pod), Some(&spec));

        assert_eq!(pod_spec(&json!({ "kind": "Service", "spec": {} })), None);
        assert_eq!(pod_spec(&json!({ "spec": {} })), None);
        assert_eq!(pod_spec(&json!({ "kind": "Deployment" })), None);
    }
}
