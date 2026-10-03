//! What the apiserver answered for each object of a dry-run deploy.
//!
//! A dry-run deploy runs the same engine as a real one with every write sent
//! as `dryRun=All` (`KubeOpsConfig::dry_run`). The engine only needs a
//! verdict per node, but `kix plan` reports what each write would do, so
//! [`super::ops::KubeOps`] keeps the apiserver's answers in a [`Journal`]:
//! the object an apply would produce, or the typed reason it was refused.

use std::sync::Mutex;

use serde_json::Value;

use crate::manifest::types::ResourceId;

use super::apply::{ApplyError, ApplyPreview};
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
    /// The object would be deleted and created again: a changed field is
    /// immutable and the plan authorises the delete, or the object is a Job
    /// under `kix.run/rerun`. `result` is `None` when the dry-run create
    /// could not run because the object still exists.
    Recreated {
        live: Option<Value>,
        result: Option<Value>,
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
            | Refusal::Invalid { message, .. }
            | Refusal::Forbidden { message }
            | Refusal::NamespaceMissing { message, .. }
            | Refusal::Hydration { message }
            | Refusal::Other { message } => message.clone(),
            Refusal::UnknownKind { kind } => {
                format!("the apiserver does not serve kind {kind}")
            }
        }
    }

    /// Classify an apply failure.
    pub fn of_apply(err: &ApplyError) -> Refusal {
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

    pub fn of_hydration(err: &SecretError) -> Refusal {
        Refusal::Hydration {
            message: err.to_string(),
        }
    }

    /// Classify an apiserver error status by its code and message. The
    /// messages are the apiserver's own wording (`k8s.io/apiserver`
    /// admission and `structured-merge-diff` conflicts).
    pub fn of_status(code: u16, message: &str) -> Option<Refusal> {
        let message = message.to_string();
        if message.contains("does not support dry run") {
            return Some(Refusal::WebhookNoDryRun {
                webhook: quoted_after(&message, "admission webhook "),
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

/// The double-quoted name right after `prefix`: `admission webhook "x"`.
fn quoted_after(message: &str, prefix: &str) -> Option<String> {
    quoted_after_with(message, prefix, '"')
}

/// The name in `quote` characters right after `prefix`. The apiserver
/// quotes a ValidatingAdmissionPolicy's name with `'`.
fn quoted_after_with(message: &str, prefix: &str, quote: char) -> Option<String> {
    let rest = &message[message.find(prefix)? + prefix.len()..];
    let rest = rest.strip_prefix(quote)?;
    Some(rest[..rest.find(quote)?].to_string())
}

/// The managers and fields of an SSA conflict message. One conflict reads
/// `Apply failed with 1 conflict: conflict with "kubectl-scale" using
/// apps/v1: .spec.replicas`; several list each manager's fields as
/// `- .path` lines under `conflicts with "m" using v:`.
pub fn conflict_owners(message: &str) -> Vec<ConflictOwner> {
    let mut owners: Vec<ConflictOwner> = Vec::new();
    let mut rest = message;
    while let Some(at) = rest.find(" with \"") {
        let after = &rest[at + " with \"".len()..];
        let Some(end) = after.find('"') else { break };
        let manager = after[..end].to_string();
        let tail = &after[end + 1..];
        let next = tail.find(" with \"").unwrap_or(tail.len());
        let fields: Vec<String> = tail[..next]
            .split(|c: char| c.is_whitespace() || c == ',')
            .filter(|t| t.len() > 1 && t.starts_with('.'))
            .map(str::to_string)
            .collect();
        match owners.iter_mut().find(|o| o.manager == manager) {
            Some(o) => o.fields.extend(fields),
            None => owners.push(ConflictOwner { manager, fields }),
        }
        rest = &tail[next..];
    }
    owners
}

/// The answers a dry run collected, in the order they arrived.
#[derive(Debug, Default)]
pub struct Journal {
    answers: Mutex<Vec<DryRunAnswer>>,
}

impl Journal {
    pub fn record(&self, rid: ResourceId, outcome: DryRunOutcome) {
        if let Ok(mut answers) = self.answers.lock() {
            answers.push(DryRunAnswer { rid, outcome });
        }
    }

    pub fn take(&self) -> Vec<DryRunAnswer> {
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
