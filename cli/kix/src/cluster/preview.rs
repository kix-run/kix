//! Per-resource dry-run outcomes recorded during `kix plan`.
//!
//! A dry-run deploy executes the deploy engine with `dryRun=All`
//! (`super::ops::DryRun`) and records each API server response in a [`Journal`],
//! capturing either the resulting object or a typed [`Refusal`].

use std::sync::Mutex;

use serde_json::Value;

use crate::manifest::types::ResourceId;

use super::apply::{ApplyError, ApplyPreview};
use super::kept::NotKeptField;
use super::secrets::SecretError;

/// One object's answer from a dry run.
#[derive(Debug, Clone)]
pub struct DryRunAnswer {
    pub rid: ResourceId,
    pub outcome: DryRunOutcome,
}

#[derive(Debug, Clone)]
pub enum DryRunOutcome {
    /// The apiserver accepted the apply.
    Applied(Box<ApplyPreview>),
    /// The object would be deleted and recreated because an immutable field
    /// changed (and the plan authorizes deletion) or because it is a Job with
    /// `kix.run/rerun`. `result` is `None` when the dry-run create could not
    /// run while the live object still exists.
    Recreated {
        live: Option<Value>,
        result: Option<Value>,
        /// Fields of the manifest sent that `result` does not keep as sent.
        not_kept: Vec<NotKeptField>,
    },
    /// The apiserver, or the engine before it, refused the write.
    Refused(Refusal),
    /// A prune delete under `--prune`.
    Pruned(PruneAnswer),
}

/// What a dry-run prune delete found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PruneAnswer {
    /// The delete was accepted, or the object is already gone.
    Deleted,
    /// Another Kix cluster's current build contains it, so it stays.
    KeptShared(String),
    /// It changed since it was read, so it stays.
    KeptChanged,
    Refused(String),
}

/// Why a write was refused, sorted by what the reader does about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// Another field manager owns fields this apply sets (HTTP 409).
    Conflict {
        owners: Vec<ConflictOwner>,
        message: String,
    },
    /// An admission webhook denied the request.
    WebhookDenied {
        webhook: Option<String>,
        message: String,
    },
    /// A ValidatingAdmissionPolicy denied the request.
    PolicyDenied {
        policy: Option<String>,
        message: String,
    },
    /// An admission webhook that is not declared free of side effects would
    /// be called, so the apiserver refuses the dry run. A real apply is not
    /// refused for this, so the object was not checked.
    WebhookNoDryRun {
        webhook: Option<String>,
        message: String,
    },
    /// The apiserver could not reach the Service behind an admission
    /// webhook: the Service does not exist, has no endpoints, or refused the
    /// connection. The webhook did not answer. [`super::classify`] decides
    /// whether the deploy repairs it.
    WebhookUnreachable {
        webhook: Option<String>,
        service: ResourceId,
        message: String,
    },
    /// The object fails validation (HTTP 422): schema, a CRD's rules, or a
    /// field Kubernetes does not allow to change.
    Invalid {
        immutable: bool,
        message: String,
    },
    /// The request was forbidden (HTTP 403): RBAC, or an admission plugin
    /// such as PVC resize on a storage class that cannot expand.
    Forbidden {
        message: String,
    },
    /// The object's namespace does not exist (HTTP 404).
    NamespaceMissing {
        namespace: String,
        message: String,
    },
    /// The apiserver does not serve the kind.
    UnknownKind {
        kind: String,
    },
    /// A SOPS Secret could not be decrypted, so nothing was sent.
    Hydration {
        message: String,
    },
    /// A SOPS Secret's decrypted values do not match its declared `hash`, so
    /// nothing was sent. `sops_source` is the Secret's `kix.run/sops-source`.
    HashMismatch {
        sops_source: String,
        message: String,
    },
    Other {
        message: String,
    },
}

/// One field manager named in a 409, with the fields it owns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConflictOwner {
    pub manager: String,
    pub fields: Vec<String>,
}

impl Refusal {
    pub fn message(&self) -> String {
        match self {
            Refusal::Conflict { message, .. }
            | Refusal::WebhookDenied { message, .. }
            | Refusal::PolicyDenied { message, .. }
            | Refusal::WebhookNoDryRun { message, .. }
            | Refusal::WebhookUnreachable { message, .. }
            | Refusal::Invalid { message, .. }
            | Refusal::Forbidden { message }
            | Refusal::NamespaceMissing { message, .. }
            | Refusal::Hydration { message }
            | Refusal::HashMismatch { message, .. }
            | Refusal::Other { message } => message.clone(),
            Refusal::UnknownKind { kind } => {
                format!("the apiserver does not serve kind {kind}")
            }
        }
    }

    /// Classify an apply failure.
    pub(crate) fn of_apply(err: &ApplyError) -> Refusal {
        let source = match err {
            ApplyError::UnknownKind { kind } => {
                return Refusal::UnknownKind { kind: kind.clone() };
            }
            ApplyError::PatchFailed { source, .. }
            | ApplyError::Conflict { source, .. }
            | ApplyError::ImmutableConflict { source, .. }
            | ApplyError::CrdStoredVersion { source, .. }
            | ApplyError::BookkeepingAnnotationsFailed { source, .. } => source,
            ApplyError::ExpectationUnmet { .. } | ApplyError::NoNamespace { .. } => {
                return Refusal::Other {
                    message: err.to_string(),
                };
            }
        };
        let kube::Error::Api(resp) = source else {
            return Refusal::Other {
                message: err.to_string(),
            };
        };
        Refusal::of_status(resp.code, &resp.message)
            .unwrap_or_else(|| Refusal::Other {
                message: resp.message.clone(),
            })
            .immutable_if(matches!(err, ApplyError::ImmutableConflict { .. }))
    }

    /// Classify a secret hydration failure.
    pub(crate) fn of_hydration(err: &SecretError) -> Refusal {
        match err {
            SecretError::HashMismatch {
                name, sops_source, ..
            } => Refusal::HashMismatch {
                message: format!(
                    "the values in SOPS file {} do not match the `hash` declared for Secret '{name}'. {}",
                    super::secrets::sops_file_name(sops_source),
                    super::secrets::hash_mismatch_next(sops_source, None)
                ),
                sops_source: sops_source.clone(),
            },
            _ => Refusal::Hydration {
                message: err.to_string(),
            },
        }
    }

    /// Classify an apiserver error status by its code and message. The
    /// messages are the apiserver's own wording (`k8s.io/apiserver`
    /// admission and `structured-merge-diff` conflicts).
    pub(crate) fn of_status(code: u16, message: &str) -> Option<Refusal> {
        let message = message.to_string();
        if message.contains("does not support dry run") {
            return Some(Refusal::WebhookNoDryRun {
                webhook: quoted_after(&message, "admission webhook "),
                message,
            });
        }
        if let Some(service) = unreachable_webhook_service(&message) {
            return Some(Refusal::WebhookUnreachable {
                webhook: quoted_after(&message, "failed calling webhook "),
                service,
                message,
            });
        }
        if message.contains("admission webhook") && message.contains("denied the request") {
            return Some(Refusal::WebhookDenied {
                webhook: quoted_after(&message, "admission webhook "),
                message,
            });
        }
        if message.contains("ValidatingAdmissionPolicy") && message.contains("denied request") {
            return Some(Refusal::PolicyDenied {
                policy: quoted_after_with(&message, "ValidatingAdmissionPolicy ", '\''),
                message,
            });
        }
        match code {
            409 => Some(Refusal::Conflict {
                owners: conflict_owners(&message),
                message,
            }),
            422 => Some(Refusal::Invalid {
                immutable: message.contains("immutable")
                    || message.contains("Forbidden: updates to"),
                message,
            }),
            403 => Some(Refusal::Forbidden { message }),
            404 => quoted_after(&message, "namespaces ")
                .filter(|_| message.contains("not found"))
                .map(|namespace| Refusal::NamespaceMissing { namespace, message }),
            _ => None,
        }
    }

    fn immutable_if(self, immutable: bool) -> Refusal {
        match self {
            Refusal::Invalid { message, .. } if immutable => Refusal::Invalid {
                immutable: true,
                message,
            },
            other => other,
        }
    }
}

/// Return the Service an admission webhook call could not reach, read from
/// the apiserver's `failed calling webhook "x": failed to call webhook: Post
/// "https://<service>.<namespace>.svc:443/...": <cause>` message. Return
/// `None` when the call failed for another cause, or when the webhook names a
/// URL outside the cluster.
fn unreachable_webhook_service(message: &str) -> Option<ResourceId> {
    if !message.contains("failed calling webhook") {
        return None;
    }
    let unreachable = (message.contains("service \"") && message.contains("\" not found"))
        || message.contains("no endpoints available for service")
        || message.contains("connection refused");
    if !unreachable {
        return None;
    }
    let rest = &message[message.find("://")? + "://".len()..];
    let host = &rest[..rest.find([':', '/', '"'])?];
    let mut labels = host.split('.');
    let (name, namespace) = (labels.next()?, labels.next()?);
    if labels.next() != Some("svc") || name.is_empty() || namespace.is_empty() {
        return None;
    }
    Some(ResourceId {
        kind: "Service".into(),
        namespace: namespace.into(),
        name: name.into(),
    })
}

/// Extract the double-quoted name immediately after `prefix` (for example,
/// `admission webhook "x"`).
fn quoted_after(message: &str, prefix: &str) -> Option<String> {
    quoted_after_with(message, prefix, '"')
}

/// Extract the name enclosed in `quote` immediately after `prefix`.
fn quoted_after_with(message: &str, prefix: &str, quote: char) -> Option<String> {
    let rest = &message[message.find(prefix)? + prefix.len()..];
    let rest = rest.strip_prefix(quote)?;
    Some(rest[..rest.find(quote)?].to_string())
}

/// Parse conflicting field managers and their owned field paths from a
/// server-side apply 409 message.
pub(crate) fn conflict_owners(message: &str) -> Vec<ConflictOwner> {
    let mut owners: Vec<ConflictOwner> = Vec::new();
    let mut rest = message;
    while let Some(at) = rest.find(" with \"") {
        let after = &rest[at + " with \"".len()..];
        let Some(end) = after.find('"') else { break };
        let manager = after[..end].to_string();
        let tail = &after[end + 1..];
        let next = tail.find(" with \"").unwrap_or(tail.len());
        let fields = field_paths(&tail[..next]);
        match owners.iter_mut().find(|o| o.manager == manager) {
            Some(o) => o.fields.extend(fields),
            None => owners.push(ConflictOwner { manager, fields }),
        }
        rest = &tail[next..];
    }
    owners
}

/// Extract `.`-prefixed field paths from `text`, splitting on whitespace and
/// commas outside brackets so keyed list selectors stay intact.
fn field_paths(text: &str) -> Vec<String> {
    let mut paths = Vec::new();
    let mut current = String::new();
    let mut depth = 0usize;
    for c in text.chars() {
        match c {
            '[' => depth += 1,
            ']' => depth = depth.saturating_sub(1),
            _ => {}
        }
        if depth == 0 && (c.is_whitespace() || c == ',') {
            paths.push(std::mem::take(&mut current));
        } else {
            current.push(c);
        }
    }
    paths.push(current);
    paths
        .into_iter()
        .filter(|t| t.len() > 1 && t.starts_with('.'))
        .collect()
}

/// The answers a dry run collected, in the order they arrived.
#[derive(Debug, Default)]
pub(crate) struct Journal {
    answers: Mutex<Vec<DryRunAnswer>>,
}

impl Journal {
    pub(crate) fn record(&self, rid: ResourceId, outcome: DryRunOutcome) {
        if let Ok(mut answers) = self.answers.lock() {
            answers.push(DryRunAnswer { rid, outcome });
        }
    }

    pub(crate) fn take(&self) -> Vec<DryRunAnswer> {
        self.answers
            .lock()
            .map(|mut a| std::mem::take(&mut *a))
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_single_conflict_names_its_manager_and_field() {
        let msg = "Apply failed with 1 conflict: conflict with \"kubectl-scale\" using apps/v1: .spec.replicas";
        assert_eq!(
            conflict_owners(msg),
            vec![ConflictOwner {
                manager: "kubectl-scale".into(),
                fields: vec![".spec.replicas".into()],
            }]
        );
        assert!(matches!(
            Refusal::of_status(409, msg),
            Some(Refusal::Conflict { .. })
        ));
    }

    #[test]
    fn several_conflicts_keep_each_managers_fields_apart() {
        let msg = "Apply failed with 3 conflicts: conflicts with \"helm\" using apps/v1:\n- .spec.replicas\n- .spec.template.spec.containers[name=\"web\"].image\nconflicts with \"kubectl-edit\" using apps/v1:\n- .metadata.labels.tier";
        let owners = conflict_owners(msg);
        assert_eq!(owners.len(), 2);
        assert_eq!(owners[0].manager, "helm");
        assert_eq!(
            owners[0].fields,
            vec![
                ".spec.replicas",
                ".spec.template.spec.containers[name=\"web\"].image"
            ]
        );
        assert_eq!(owners[1].manager, "kubectl-edit");
        assert_eq!(owners[1].fields, vec![".metadata.labels.tier"]);
    }

    #[test]
    fn a_list_key_with_a_comma_stays_one_field() {
        let msg = "Apply failed with 2 conflicts: conflicts with \"helm\" using apps/v1:\n- .spec.selector\n- .spec.template.spec.containers[name=\"coredns\"].ports[containerPort=53,protocol=\"UDP\"].name";
        assert_eq!(
            conflict_owners(msg)[0].fields,
            vec![
                ".spec.selector",
                ".spec.template.spec.containers[name=\"coredns\"].ports[containerPort=53,protocol=\"UDP\"].name",
            ]
        );
    }

    #[test]
    fn webhook_answers_are_told_apart() {
        let denied = "admission webhook \"validate.nginx.ingress.kubernetes.io\" denied the request: host \"a\" is already defined";
        assert_eq!(
            Refusal::of_status(400, denied),
            Some(Refusal::WebhookDenied {
                webhook: Some("validate.nginx.ingress.kubernetes.io".into()),
                message: denied.into(),
            })
        );
        let no_dry_run = "admission webhook \"policy.example.com\" does not support dry run";
        assert!(matches!(
            Refusal::of_status(400, no_dry_run),
            Some(Refusal::WebhookNoDryRun { webhook: Some(w), .. }) if w == "policy.example.com"
        ));
    }

    fn service(namespace: &str, name: &str) -> ResourceId {
        ResourceId {
            kind: "Service".into(),
            namespace: namespace.into(),
            name: name.into(),
        }
    }

    #[test]
    fn a_webhook_whose_service_is_missing_is_unreachable() {
        let missing = "Internal error occurred: failed calling webhook \"mcluster.cnpg.io\": failed to call webhook: Post \"https://cnpg-webhook-service.cnpg-system.svc:443/mutate-postgresql-cnpg-io-v1-cluster?timeout=10s\": service \"cnpg-webhook-service\" not found";
        assert_eq!(
            Refusal::of_status(500, missing),
            Some(Refusal::WebhookUnreachable {
                webhook: Some("mcluster.cnpg.io".into()),
                service: service("cnpg-system", "cnpg-webhook-service"),
                message: missing.into(),
            })
        );
        for cause in [
            "no endpoints available for service \"cnpg-webhook-service\"",
            "dial tcp 10.96.12.7:443: connect: connection refused",
        ] {
            let msg = format!(
                "Internal error occurred: failed calling webhook \"vcluster.cnpg.io\": failed to call webhook: Post \"https://cnpg-webhook-service.cnpg-system.svc:443/validate?timeout=10s\": {cause}"
            );
            assert!(matches!(
                Refusal::of_status(500, &msg),
                Some(Refusal::WebhookUnreachable { service: s, .. })
                    if s == service("cnpg-system", "cnpg-webhook-service")
            ));
        }
    }

    #[test]
    fn other_webhook_failures_are_not_unreachable_services() {
        // A webhook that answered with a denial is a real refusal.
        let denied = "admission webhook \"vcluster.cnpg.io\" denied the request: spec.instances: Invalid value: 0";
        assert!(matches!(
            Refusal::of_status(400, denied),
            Some(Refusal::WebhookDenied { .. })
        ));
        // A webhook that names a URL outside the cluster has no Service to
        // create.
        let external = "Internal error occurred: failed calling webhook \"x.example.com\": failed to call webhook: Post \"https://hooks.example.com:443/x\": dial tcp 1.2.3.4:443: connect: connection refused";
        assert_eq!(Refusal::of_status(500, external), None);
        // A Service that answers but fails the TLS check is not missing.
        let tls = "Internal error occurred: failed calling webhook \"x.io\": failed to call webhook: Post \"https://x.ns.svc:443/x\": tls: failed to verify certificate: x509: certificate signed by unknown authority";
        assert_eq!(Refusal::of_status(500, tls), None);
    }

    #[test]
    fn an_admission_policy_denial_names_the_policy() {
        let msg = "configmaps \"grafana-config\" is forbidden: ValidatingAdmissionPolicy 'freeze' with binding 'freeze-b' denied request: frozen";
        assert_eq!(
            Refusal::of_status(403, msg),
            Some(Refusal::PolicyDenied {
                policy: Some("freeze".into()),
                message: msg.into(),
            })
        );
    }

    #[test]
    fn an_immutable_spec_is_told_apart_from_other_validation() {
        let pvc = "PersistentVolumeClaim \"data\" is invalid: spec: Forbidden: spec is immutable after creation except resources.requests";
        assert!(matches!(
            Refusal::of_status(422, pvc),
            Some(Refusal::Invalid {
                immutable: true,
                ..
            })
        ));
        let schema = "Deployment.apps \"web\" is invalid: spec.replicas: Invalid value: -1";
        assert!(matches!(
            Refusal::of_status(422, schema),
            Some(Refusal::Invalid {
                immutable: false,
                ..
            })
        ));
    }

    #[test]
    fn a_missing_namespace_is_named() {
        let msg = "namespaces \"immich\" not found";
        assert_eq!(
            Refusal::of_status(404, msg),
            Some(Refusal::NamespaceMissing {
                namespace: "immich".into(),
                message: msg.into(),
            })
        );
        assert_eq!(Refusal::of_status(404, "configmaps \"x\" not found"), None);
    }
}
