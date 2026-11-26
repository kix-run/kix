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
    /// The pod annotation that tells the platform to leave some containers
    /// alone. Those containers are not checked.
    #[serde(default)]
    pub skip: Option<SkipAnnotation>,
    /// The other mechanisms of the same cloud, so a pod that got one of them
    /// instead is named as such.
    #[serde(default)]
    pub alternatives: Vec<Alternative>,
}

/// A pod annotation that lists containers the platform does not change.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(crate) struct SkipAnnotation {
    pub annotation: String,
    pub separator: String,
}

/// Another mechanism of the same cloud, by the variables it adds.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(crate) struct Alternative {
    pub description: String,
    pub env: Vec<String>,
    /// What to do when a pod got this mechanism instead.
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
/// declared values. A container that the pod's skip annotation names is not
/// checked, because the platform was told to leave it alone. A container that
/// carries every variable of an alternative mechanism is reported as having
/// got that mechanism.
pub(crate) fn classify_pod_identity(pod: &Value, expected: &IdentityEnv) -> Option<String> {
    let pod_name = pod
        .pointer("/metadata/name")
        .and_then(Value::as_str)
        .unwrap_or("?");
    let account = pod
        .pointer("/spec/serviceAccountName")
        .and_then(Value::as_str)
        .unwrap_or("default");
    let skipped: Vec<&str> = expected
        .skip
        .as_ref()
        .and_then(|s| {
            let list = pod
                .pointer("/metadata/annotations")
                .and_then(Value::as_object)?
                .get(&s.annotation)?
                .as_str()?;
            Some(list.split(s.separator.as_str()).map(str::trim).collect())
        })
        .unwrap_or_default();
    let containers = pod.pointer("/spec/containers").and_then(Value::as_array)?;
    for container in containers {
        let name = container.get("name").and_then(Value::as_str).unwrap_or("?");
        if skipped.contains(&name) {
            continue;
        }
        let env: BTreeMap<&str, Option<&str>> = container
            .get("env")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|e| {
                let key = e.get("name").and_then(Value::as_str)?;
                // `None` stands for a value from `valueFrom`, which Kix cannot
                // read. An entry with neither field holds the empty string.
                let value = match e.get("value").and_then(Value::as_str) {
                    Some(v) => Some(v),
                    None if e.get("valueFrom").is_some() => None,
                    None => Some(""),
                };
                Some((key, value))
            })
            .collect();
        let missing: Vec<&str> = expected
            .env
            .keys()
            .map(String::as_str)
            .filter(|k| !env.contains_key(k))
            .collect();
        // A variable the container already carries with another value. The
        // platform does not replace a variable a container sets itself.
        let differs = expected.env.iter().find_map(|(key, want)| {
            let want = want.as_deref()?;
            let got = env.get(key.as_str())?;
            (*got != Some(want)).then_some((key.as_str(), *got, want))
        });
        // A container that carries every variable of another mechanism got
        // that mechanism from the platform instead.
        let instead = expected
            .alternatives
            .iter()
            .find(|a| !a.env.is_empty() && a.env.iter().all(|k| env.contains_key(k.as_str())));
        let problem: Option<(String, Option<String>)> = if let (false, Some(other)) =
            (missing.is_empty(), instead)
        {
            let names: Vec<&str> = other.env.iter().map(String::as_str).collect();
            Some((
                format!(
                    "container `{name}` has {}, so the cluster applied {} instead of {}",
                    quoted_list(&names),
                    other.description,
                    expected.description
                ),
                other.fix.clone().or_else(|| expected.fix.clone()),
            ))
        } else if let Some((key, got, want)) = differs {
            let got = got.map_or_else(
                || "a value from `valueFrom`".to_string(),
                |g| format!("`{g}`"),
            );
            let also = if missing.is_empty() {
                String::new()
            } else {
                format!(" and is missing {}", quoted_list(&missing))
            };
            let exempt = expected
                .skip
                .as_ref()
                .map(|s| {
                    format!(
                        " If this container should keep its own credentials, add its name to the pod annotation `{}` and deploy again.",
                        s.annotation
                    )
                })
                .unwrap_or_default();
            Some((
                format!(
                    "container `{name}` already sets `{key}` to {got} (expected `{want}`){also}. {} does not overwrite a container's existing environment variables",
                    expected.description
                ),
                Some(format!(
                    "Remove `{key}` from `env` on container `{name}`, then deploy again.{exempt}"
                )),
            ))
        } else if !missing.is_empty() {
            Some((
                format!(
                    "container `{name}` is missing {}, which {} sets",
                    quoted_list(&missing),
                    expected.description
                ),
                expected.fix.clone(),
            ))
        } else {
            None
        };
        if let Some((problem, fix)) = problem {
            let fix = fix.map(|f| format!(" {f}")).unwrap_or_default();
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
            "fix": "Delete the association.",
            "skip": { "annotation": "eks.amazonaws.com/skip-containers", "separator": "," },
            "alternatives": [{
                "description": "EKS Pod Identity",
                "env": ["AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE", "AWS_CONTAINER_CREDENTIALS_FULL_URI"],
                "fix": "Delete the EKS Pod Identity association."
            }]
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
                "container `worker` already sets `AWS_ROLE_ARN` to `arn:aws:iam::111122223333:role/other` (expected `arn:aws:iam::111122223333:role/worker`)"
            ),
            "{message}"
        );
        assert!(
            message.ends_with("Remove `AWS_ROLE_ARN` from `env` on container `worker`, then deploy again. If this container should keep its own credentials, add its name to the pod annotation `eks.amazonaws.com/skip-containers` and deploy again."),
            "{message}"
        );
        assert!(!message.contains("Delete the association"), "{message}");
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

    // An EKS Pod Identity association takes precedence over IRSA. The pod
    // then carries the Pod Identity variables, and the message says so as a
    // fact, with the alternative's own fix.
    #[test]
    fn a_pod_that_got_another_mechanism_is_named() {
        let p = pod(json!([
            { "name": "AWS_CONTAINER_CREDENTIALS_FULL_URI", "value": "http://169.254.170.23/v1/credentials" },
            { "name": "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE", "value": "/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token" }
        ]));
        let message = classify_pod_identity(&p, &irsa()).expect("refused");
        assert!(
            message.contains("so the cluster applied EKS Pod Identity instead of IAM roles for service accounts (IRSA)"),
            "{message}"
        );
        assert!(
            message.ends_with("Delete the EKS Pod Identity association."),
            "{message}"
        );
    }

    // A container the pod's skip annotation names is left alone by the
    // platform, so it is not checked. Another container still is.
    #[test]
    fn a_skipped_container_is_not_checked() {
        let mut p = pod(json!([]));
        p["metadata"]["annotations"] =
            json!({ "eks.amazonaws.com/skip-containers": "worker, other" });
        assert_eq!(classify_pod_identity(&p, &irsa()), None);
        p["metadata"]["annotations"] = json!({ "eks.amazonaws.com/skip-containers": "other" });
        assert!(classify_pod_identity(&p, &irsa()).is_some());
    }

    // A sidecar that sets its own `AWS_ROLE_ARN` is left alone by the
    // webhook, so it also lacks the token file. The message names the
    // differing value first, and the missing variable after it.
    #[test]
    fn a_container_with_its_own_role_names_both_values() {
        let p = pod(json!([
            { "name": "AWS_ROLE_ARN", "value": "arn:aws:iam::111122223333:role/sidecar" }
        ]));
        let message = classify_pod_identity(&p, &irsa()).expect("refused");
        assert!(
            message.contains("already sets `AWS_ROLE_ARN` to `arn:aws:iam::111122223333:role/sidecar` (expected `arn:aws:iam::111122223333:role/worker`) and is missing `AWS_WEB_IDENTITY_TOKEN_FILE`"),
            "{message}"
        );
        assert!(message.contains("Remove `AWS_ROLE_ARN`"), "{message}");
    }
}
