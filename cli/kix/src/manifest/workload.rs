//! Where a manifest keeps its pod template.
//!
//! Every reader of containers, images or placement rules has to know that a
//! Deployment's pod spec is at `spec.template.spec`, a CronJob's one level
//! deeper, and a bare Pod's at `spec`. Three commands used to carry that
//! table each; this is the one copy, so a kind added here is seen by all.

use serde_json::Value;

/// The pod spec a manifest would create pods from, or `None` for a kind
/// that has no pod template.
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
