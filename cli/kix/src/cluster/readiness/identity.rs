//! Check that a workload's new pods got the cloud identity the definition
//! gives them.
//!
//! The Kix library writes [`keys::CLOUD_IDENTITY_ENV`] on a Deployment,
//! StatefulSet, or DaemonSet whose pods use a ServiceAccount with a cloud
//! identity, when the platform that delivers it adds environment variables to
//! each container. The platform's webhook adds them when it admits the pod, so
//! a created pod's spec says for good whether the pod got the identity. A pod
//! without them, or with another value, runs without that identity.

use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::Value;

use crate::manifest::keys;

/// What [`keys::CLOUD_IDENTITY_ENV`] says about a workload's pods.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(crate) struct IdentityEnv {
    /// How messages name the mechanism, such as "EKS Pod Identity".
    pub description: String,
    /// Each variable the platform adds to every container, with the value it
    /// must have, or `None` when only its presence is known.
    pub env: BTreeMap<String, Option<String>>,
    /// What to check when a pod lacks them.
    #[serde(default)]
    pub fix: Option<String>,
}

/// Return the cloud identity variables that a workload's annotations
/// declare, or `None` when they declare none. A value Kix cannot read is
/// skipped, because a malformed declaration says nothing about the platform.
pub(crate) fn identity_env(annotations: &BTreeMap<String, String>) -> Option<IdentityEnv> {
    let raw = keys::get_meta(annotations, keys::CLOUD_IDENTITY_ENV)?;
    match serde_json::from_str::<IdentityEnv>(raw) {
        Ok(parsed) if !parsed.env.is_empty() => Some(parsed),
        Ok(_) => None,
        Err(e) => {
            tracing::debug!(error = %e, annotation = keys::CLOUD_IDENTITY_ENV, "invalid annotation; skipping pod identity check");
            None
        }
    }
}

/// Return why `pod` did not get the cloud identity that `expected` describes,
/// or `None` when every container carries the declared variables with the
/// declared values.
pub(crate) fn classify_pod_identity(pod: &Value, expected: &IdentityEnv) -> Option<String> {
    let pod_name = pod
        .pointer("/metadata/name")
        .and_then(Value::as_str)
        .unwrap_or("?");
    let account = pod
        .pointer("/spec/serviceAccountName")
        .and_then(Value::as_str)
        .unwrap_or("default");
    let containers = pod.pointer("/spec/containers").and_then(Value::as_array)?;
    for container in containers {
        let name = container.get("name").and_then(Value::as_str).unwrap_or("?");
        let env: BTreeMap<&str, Option<&str>> = container
            .get("env")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|e| {
                let key = e.get("name").and_then(Value::as_str)?;
                Some((key, e.get("value").and_then(Value::as_str)))
            })
            .collect();
        let missing: Vec<&str> = expected
            .env
            .keys()
            .map(String::as_str)
            .filter(|k| !env.contains_key(k))
            .collect();
        let problem = if !missing.is_empty() {
            Some(format!(
                "container `{name}` is missing {}, which {} sets",
                quoted_list(&missing),
                expected.description
            ))
        } else {
            expected.env.iter().find_map(|(key, want)| {
                let want = want.as_deref()?;
                let got = env.get(key.as_str()).copied().flatten().unwrap_or("");
                (got != want).then(|| {
                    format!(
                        "container `{name}` has `{key}` set to `{got}`, but Kix expected `{want}`"
                    )
                })
            })
        };
        if let Some(problem) = problem {
            let fix = expected
                .fix
                .as_deref()
                .map(|f| format!(" {f}"))
                .unwrap_or_default();
            return Some(format!(
                "pod {pod_name} (ServiceAccount `{account}`) did not receive its cloud identity: {problem}. Kix stopped waiting for this workload.{fix}"
            ));
        }
    }
    None
}

fn quoted_list(names: &[&str]) -> String {
    let quoted: Vec<String> = names.iter().map(|n| format!("`{n}`")).collect();
    match quoted.as_slice() {
        [] => String::new(),
        [one] => one.clone(),
        [first, second] => format!("{first} and {second}"),
        [init @ .., last] => format!("{}, and {last}", init.join(", ")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const ROLE: &str = "arn:aws:iam::111122223333:role/worker";

    fn annotations(value: Value) -> BTreeMap<String, String> {
        BTreeMap::from([(keys::CLOUD_IDENTITY_ENV.to_string(), value.to_string())])
    }

    fn irsa() -> IdentityEnv {
        identity_env(&annotations(json!({
            "description": "IAM roles for service accounts (IRSA)",
            "env": { "AWS_ROLE_ARN": ROLE, "AWS_WEB_IDENTITY_TOKEN_FILE": null },
            "fix": "Delete the association."
        })))
        .expect("declared")
    }

    fn pod(env: Value) -> Value {
        json!({
            "metadata": { "name": "worker-1" },
            "spec": {
                "serviceAccountName": "worker",
                "containers": [ { "name": "worker", "env": env } ]
            }
        })
    }

    #[test]
    fn reads_the_declaration_and_skips_what_it_cannot_read() {
        let parsed = irsa();
        assert_eq!(
            parsed.env.get("AWS_ROLE_ARN"),
            Some(&Some(ROLE.to_string()))
        );
        assert_eq!(parsed.env.get("AWS_WEB_IDENTITY_TOKEN_FILE"), Some(&None));
        assert_eq!(identity_env(&BTreeMap::new()), None);
        let mut bad = BTreeMap::new();
        bad.insert(keys::CLOUD_IDENTITY_ENV.to_string(), "{".to_string());
        assert_eq!(identity_env(&bad), None);
        let empty = annotations(json!({ "description": "GKE", "env": {} }));
        assert_eq!(identity_env(&empty), None);
    }

    #[test]
    fn a_pod_with_the_injected_variables_passes() {
        let p = pod(json!([
            { "name": "AWS_ROLE_ARN", "value": ROLE },
            { "name": "AWS_WEB_IDENTITY_TOKEN_FILE", "value": "/var/run/secrets/eks.amazonaws.com/serviceaccount/token" }
        ]));
        assert_eq!(classify_pod_identity(&p, &irsa()), None);
    }

    // An EKS Pod Identity association takes precedence over IRSA, so the
    // pod gets the Pod Identity variables and no `AWS_ROLE_ARN`.
    #[test]
    fn a_pod_without_the_injected_variables_fails() {
        let p = pod(json!([
            { "name": "AWS_CONTAINER_CREDENTIALS_FULL_URI", "value": "http://169.254.170.23/v1/credentials" }
        ]));
        let message = classify_pod_identity(&p, &irsa()).expect("refused");
        assert_eq!(
            message,
            "pod worker-1 (ServiceAccount `worker`) did not receive its cloud identity: container `worker` is missing `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE`, which IAM roles for service accounts (IRSA) sets. Kix stopped waiting for this workload. Delete the association."
        );
        let bare = json!({
            "metadata": { "name": "worker-1" },
            "spec": { "containers": [ { "name": "worker" } ] }
        });
        assert!(
            classify_pod_identity(&bare, &irsa())
                .expect("refused")
                .contains("ServiceAccount `default`")
        );
    }

    #[test]
    fn a_pod_with_another_value_fails() {
        let p = pod(json!([
            { "name": "AWS_ROLE_ARN", "value": "arn:aws:iam::111122223333:role/other" },
            { "name": "AWS_WEB_IDENTITY_TOKEN_FILE", "value": "/token" }
        ]));
        let message = classify_pod_identity(&p, &irsa()).expect("refused");
        assert!(
            message.contains(
                "has `AWS_ROLE_ARN` set to `arn:aws:iam::111122223333:role/other`, but Kix expected `arn:aws:iam::111122223333:role/worker`"
            ),
            "{message}"
        );
    }

    // Every container must carry the variables, not only the first.
    #[test]
    fn each_container_is_checked() {
        let p = json!({
            "metadata": { "name": "worker-1" },
            "spec": {
                "serviceAccountName": "worker",
                "containers": [
                    { "name": "worker", "env": [
                        { "name": "AWS_ROLE_ARN", "value": ROLE },
                        { "name": "AWS_WEB_IDENTITY_TOKEN_FILE", "value": "/token" }
                    ] },
                    { "name": "sidecar" }
                ]
            }
        });
        let message = classify_pod_identity(&p, &irsa()).expect("refused");
        assert!(message.contains("container `sidecar`"), "{message}");
    }
}
