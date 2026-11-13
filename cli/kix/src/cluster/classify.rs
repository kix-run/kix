//! Sort a dry run's answers into accepted, refused, and not checked.
//!
//! A dry-run answer about an object is final only when the deploy does not
//! change what produced the answer. Kix can tell in four cases: the object's
//! namespace is created by the deploy, its CRD is created or changed by the
//! deploy, or its admission webhook could not reach a backend the deploy
//! writes. Each of these is "not checked". Every other refusal is final, and
//! stops the deploy before it writes anything.
//!
//! `kix plan`, the deploy gate, saved plans, and `kix rollback` all sort the
//! answers with [`classify`], so they agree on what stops.

use std::collections::{HashMap, HashSet};

use serde_json::Value;

use crate::cluster::apply::ChangeAction;
use crate::cluster::readiness;
use crate::cluster::scheduler::DeployPlan;
use crate::manifest::keys;
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};
use crate::plan::document::UncheckedReason;
use crate::plan::server::comparable;

use super::preview::{DryRunAnswer, DryRunOutcome, Refusal};

/// What one object's dry-run answer means for the deploy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// The apiserver accepted the write, or the engine recreates the object
    /// after an immutable-field refusal.
    Accepted,
    /// The deploy would stop at this object.
    Refused(Refusal),
    /// The answer depends on something this deploy changes, so it is not
    /// final.
    NotChecked {
        reason: UncheckedReason,
        /// The Namespace, CRD, or Service the answer depends on, when Kix
        /// knows which.
        because: Option<ResourceId>,
        /// One line for the reader.
        detail: String,
    },
}

/// What the classifier needs to know about the deploy.
pub struct DeployScope<'a> {
    /// The Kix cluster, for the advice a refusal gives.
    pub cluster: &'a str,
    /// Every manifest of the build being deployed.
    pub build: &'a [Value],
    /// The deploy's plan. Its apply nodes are what the deploy writes.
    pub plan: &'a DeployPlan,
    /// Kinds the apiserver serves.
    pub served_kinds: &'a HashSet<String>,
}

/// Return the verdict for each object the dry run answered for, in the order
/// of `answers`. Prune answers are not writes and get no verdict. An object
/// answered twice, refused and then recreated, gets one verdict.
pub fn classify(answers: &[DryRunAnswer], scope: &DeployScope) -> Vec<(ResourceId, Verdict)> {
    let ctx = Context::new(answers, scope);
    let recreated: HashSet<&ResourceId> = answers
        .iter()
        .filter(|a| matches!(a.outcome, DryRunOutcome::Recreated { .. }))
        .map(|a| &a.rid)
        .collect();
    let mut seen = HashSet::new();
    let mut verdicts = Vec::new();
    for answer in answers {
        let verdict = match &answer.outcome {
            DryRunOutcome::Pruned(_) => continue,
            DryRunOutcome::Applied(_) | DryRunOutcome::Recreated { .. } => Verdict::Accepted,
            // An immutable-field refusal is followed by a recreate when the
            // engine may delete the object, so the deploy does not stop.
            DryRunOutcome::Refused(_) if recreated.contains(&answer.rid) => Verdict::Accepted,
            DryRunOutcome::Refused(refusal) => ctx.refusal(&answer.rid, refusal),
        };
        if seen.insert(&answer.rid) {
            verdicts.push((answer.rid.clone(), verdict));
        }
    }
    verdicts
}

struct Context<'a> {
    scope: &'a DeployScope<'a>,
    manifests: HashMap<ResourceId, &'a Value>,
    namespaces: HashSet<&'a str>,
    crds: BuildCrds,
    changed: ChangedCrds,
    writes: HashSet<ResourceId>,
    /// The package of each object the deploy writes.
    written_packages: HashSet<String>,
}

impl<'a> Context<'a> {
    fn new(answers: &[DryRunAnswer], scope: &'a DeployScope<'a>) -> Self {
        let manifests: HashMap<ResourceId, &Value> = scope
            .build
            .iter()
            .map(|m| (ResourceId::from_value(m), m))
            .collect();
        let namespaces = scope
            .build
            .iter()
            .filter(|m| m.get("kind").and_then(Value::as_str) == Some("Namespace"))
            .filter_map(|m| m.pointer("/metadata/name").and_then(Value::as_str))
            .collect();
        let applied: Vec<&Value> = scope
            .plan
            .nodes()
            .iter()
            .filter_map(|n| match &n.action {
                ChangeAction::Apply(m) | ChangeAction::Recreate(m) => Some(m),
                ChangeAction::Skip(_) | ChangeAction::Orphan(_) => None,
            })
            .collect();
        Context {
            scope,
            namespaces,
            crds: BuildCrds::of(scope.build),
            changed: ChangedCrds::of(answers),
            writes: applied.iter().map(|m| ResourceId::from_value(m)).collect(),
            written_packages: applied.iter().filter_map(|m| package_of(m)).collect(),
            manifests,
        }
    }

    fn refusal(&self, rid: &ResourceId, refusal: &Refusal) -> Verdict {
        let manifest = self.manifests.get(rid).copied();
        let changed_crd = manifest.and_then(|m| self.changed.crd_of(m));
        match refusal {
            Refusal::WebhookNoDryRun { message, .. } => Verdict::NotChecked {
                reason: UncheckedReason::WebhookNoDryRun,
                because: None,
                detail: message.clone(),
            },
            Refusal::WebhookUnreachable {
                webhook,
                service,
                message,
            } => self.unreachable(webhook.as_deref(), service, message),
            Refusal::UnknownKind { .. } | Refusal::Invalid { .. } | Refusal::Other { .. }
                if changed_crd.is_some() =>
            {
                Verdict::NotChecked {
                    reason: UncheckedReason::CrdChangedByThisDeploy,
                    because: changed_crd.cloned(),
                    detail: "checked against the CRD now on the cluster, which this deploy \
                             changes"
                        .into(),
                }
            }
            Refusal::UnknownKind { kind }
                if !self.scope.served_kinds.contains(kind) && self.crds.brings(manifest) =>
            {
                Verdict::NotChecked {
                    reason: UncheckedReason::CrdCreatedByThisDeploy,
                    because: manifest.and_then(|m| self.crds.crd_of(m)),
                    detail: format!("kind {kind} is served once this deploy installs its CRD"),
                }
            }
            Refusal::NamespaceMissing { namespace, .. }
                if self.namespaces.contains(namespace.as_str()) =>
            {
                Verdict::NotChecked {
                    reason: UncheckedReason::NamespaceCreatedByThisDeploy,
                    because: Some(ResourceId {
                        kind: "Namespace".into(),
                        namespace: CLUSTER_SCOPED.into(),
                        name: namespace.clone(),
                    }),
                    detail: format!("namespace {namespace} is created by this deploy"),
                }
            }
            other => Verdict::Refused(other.clone()),
        }
    }

    /// Sort a write whose admission webhook could not reach `service`. The
    /// answer is not final when the deploy writes the Service, or writes
    /// another object of the package that owns it, such as the operator's
    /// Deployment. Otherwise the deploy would stop at this object, because
    /// nothing it writes repairs the webhook.
    fn unreachable(&self, webhook: Option<&str>, service: &ResourceId, message: &str) -> Verdict {
        let webhook_name = webhook.unwrap_or("?");
        let svc = service.display_id();
        let package = self.manifests.get(service).and_then(|m| package_of(m));
        if self.writes.contains(service) {
            return Verdict::NotChecked {
                reason: UncheckedReason::WebhookBackendWrittenByThisDeploy,
                because: Some(service.clone()),
                detail: format!(
                    "admission webhook {webhook_name} could not reach {svc}, which this deploy writes"
                ),
            };
        }
        if let Some(package) = package.filter(|p| self.written_packages.contains(p)) {
            return Verdict::NotChecked {
                reason: UncheckedReason::WebhookBackendWrittenByThisDeploy,
                because: Some(service.clone()),
                detail: format!(
                    "admission webhook {webhook_name} could not reach {svc}, and this deploy \
                     writes package {package}, which serves it"
                ),
            };
        }
        let cluster = self.scope.cluster;
        Verdict::Refused(Refusal::WebhookUnreachable {
            webhook: webhook.map(str::to_string),
            service: service.clone(),
            message: format!(
                "admission webhook {webhook_name} could not reach {svc}, so the webhook's backend \
                 is down. This deploy does not write {svc} or anything that serves it, so it \
                 would stop at this object. Get the backend running again first. If someone \
                 deleted {svc}, or scaled the workload behind it to 0 replicas, `kix deploy \
                 {cluster} --reconcile` restores what the build defines. The apiserver said: \
                 {message}"
            ),
        })
    }
}

/// Return the `namespace/instance` key of the package that owns `manifest`.
fn package_of(manifest: &Value) -> Option<String> {
    let name = keys::get(manifest, keys::PACKAGE)?;
    let namespace = keys::get(manifest, keys::PACKAGE_NAMESPACE)?;
    Some(format!("{namespace}/{name}"))
}

/// Return the `(group, kind)` pair for `manifest`.
fn crd_key(manifest: &Value) -> Option<(String, String)> {
    let kind = manifest.get("kind").and_then(Value::as_str)?;
    let api_version = manifest.get("apiVersion").and_then(Value::as_str)?;
    let group = api_version.split_once('/').map_or("", |(g, _)| g);
    Some((group.to_string(), kind.to_string()))
}

/// Return the `(group, kind)` pair defined by a CRD manifest.
fn defined_by(crd: &Value) -> Option<(String, String)> {
    let group = crd.pointer("/spec/group").and_then(Value::as_str)?;
    let kind = crd.pointer("/spec/names/kind").and_then(Value::as_str)?;
    Some((group.to_string(), kind.to_string()))
}

fn crd_id(name: &str) -> ResourceId {
    ResourceId {
        kind: "CustomResourceDefinition".into(),
        namespace: CLUSTER_SCOPED.into(),
        name: name.into(),
    }
}

/// The CRDs whose definition the dry run created or changed, by the
/// `(group, kind)` they define.
///
/// Custom resources of these kinds were checked against the older CRD on the
/// cluster now, which may refuse a field the new CRD adds, and prunes it.
pub struct ChangedCrds(HashMap<(String, String), ResourceId>);

impl ChangedCrds {
    pub fn of(answers: &[DryRunAnswer]) -> Self {
        let changed = answers
            .iter()
            .filter(|a| a.rid.kind == "CustomResourceDefinition")
            .filter_map(|a| match &a.outcome {
                DryRunOutcome::Applied(p) => {
                    let unchanged = p
                        .live
                        .as_ref()
                        .is_some_and(|live| comparable(live) == comparable(&p.result));
                    let key = defined_by(&p.result).filter(|_| !unchanged)?;
                    Some((key, a.rid.clone()))
                }
                _ => None,
            })
            .collect();
        ChangedCrds(changed)
    }

    /// Return the CRD this deploy changes that defines `manifest`'s kind.
    pub fn crd_of(&self, manifest: &Value) -> Option<&ResourceId> {
        self.0.get(&crd_key(manifest)?)
    }
}

/// Custom resource kinds and API groups the build brings, either as
/// `CustomResourceDefinition` manifests or through operator import markers.
struct BuildCrds {
    kinds: HashMap<(String, String), ResourceId>,
    /// The CRDs that import markers wait for, by API group.
    groups: HashMap<String, Vec<ResourceId>>,
}

impl BuildCrds {
    fn of(manifests: &[Value]) -> Self {
        let kinds = manifests
            .iter()
            .filter(|m| m.get("kind").and_then(Value::as_str) == Some("CustomResourceDefinition"))
            .filter_map(|m| Some((defined_by(m)?, ResourceId::from_value(m))))
            .collect();
        let mut groups: HashMap<String, Vec<ResourceId>> = HashMap::new();
        for target in manifests
            .iter()
            .filter_map(|m| readiness::import_target_from_manifest(m).ok().flatten())
            .filter(|t| t.kind == "CustomResourceDefinition")
        {
            if let Some((_, group)) = target.name.split_once('.') {
                groups
                    .entry(group.to_string())
                    .or_default()
                    .push(crd_id(&target.name));
            }
        }
        BuildCrds { kinds, groups }
    }

    /// Return `true` if `manifest` belongs to a CRD kind or API group the
    /// build brings.
    fn brings(&self, manifest: Option<&Value>) -> bool {
        manifest
            .and_then(crd_key)
            .is_some_and(|key| self.groups.contains_key(&key.0) || self.kinds.contains_key(&key))
    }

    /// Return the CRD that serves `manifest`'s kind. An import marker names a
    /// CRD by group only, so it counts only when it is the group's one marker.
    fn crd_of(&self, manifest: &Value) -> Option<ResourceId> {
        let key = crd_key(manifest)?;
        if let Some(crd) = self.kinds.get(&key) {
            return Some(crd.clone());
        }
        match self.groups.get(&key.0).map(Vec::as_slice) {
            Some([one]) => Some(one.clone()),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::apply::ApplyPreview;
    use serde_json::json;

    const CLUSTER: &str = "prod";

    fn crd(group: &str, kind: &str, version: &str) -> Value {
        json!({
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {"name": format!("{}s.{group}", kind.to_lowercase())},
            "spec": {"group": group, "names": {"kind": kind}, "versions": [{"name": version}]},
        })
    }

    fn object(api: &str, kind: &str, ns: &str, name: &str, package: &str) -> Value {
        json!({
            "apiVersion": api,
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": ns,
                "annotations": {keys::PACKAGE: package, keys::PACKAGE_NAMESPACE: ns},
            },
        })
    }

    fn applied(manifest: &Value, live: Option<Value>) -> DryRunAnswer {
        DryRunAnswer {
            rid: ResourceId::from_value(manifest),
            outcome: DryRunOutcome::Applied(Box::new(ApplyPreview {
                live,
                result: manifest.clone(),
                not_kept: Vec::new(),
            })),
        }
    }

    fn refused(manifest: &Value, code: u16, message: &str) -> DryRunAnswer {
        DryRunAnswer {
            rid: ResourceId::from_value(manifest),
            outcome: DryRunOutcome::Refused(Refusal::of_status(code, message).unwrap_or(
                Refusal::Other {
                    message: message.into(),
                },
            )),
        }
    }

    /// Classify `answers` for a deploy of `build` that writes `writes` and
    /// skips the rest.
    fn run(build: &[Value], writes: &[&Value], answers: &[DryRunAnswer]) -> Vec<Verdict> {
        let written: HashSet<ResourceId> =
            writes.iter().map(|m| ResourceId::from_value(m)).collect();
        let changes: Vec<ChangeAction> = build
            .iter()
            .map(|m| {
                let rid = ResourceId::from_value(m);
                if written.contains(&rid) {
                    ChangeAction::Apply(m.clone())
                } else {
                    ChangeAction::Skip(rid)
                }
            })
            .collect();
        let graph = crate::cluster::graph::ResourceGraph::from_manifests(build).unwrap();
        let plan = DeployPlan::from_graph_and_changes(&graph, &changes).unwrap();
        let served = HashSet::from(["Deployment".to_string(), "Service".to_string()]);
        let scope = DeployScope {
            cluster: CLUSTER,
            build,
            plan: &plan,
            served_kinds: &served,
        };
        classify(answers, &scope)
            .into_iter()
            .map(|(_, v)| v)
            .collect()
    }

    const SERVICE_MISSING: &str = "Internal error occurred: failed calling webhook \"mcluster.cnpg.io\": failed to call webhook: Post \"https://cnpg-webhook-service.cnpg-system.svc:443/m?timeout=10s\": service \"cnpg-webhook-service\" not found";
    const NO_ENDPOINTS: &str = "Internal error occurred: failed calling webhook \"mcluster.cnpg.io\": failed to call webhook: Post \"https://cnpg-webhook-service.cnpg-system.svc:443/m?timeout=10s\": no endpoints available for service \"cnpg-webhook-service\"";

    struct Operator {
        service: Value,
        deployment: Value,
        cluster: Value,
    }

    fn operator() -> Operator {
        Operator {
            service: object(
                "v1",
                "Service",
                "cnpg-system",
                "cnpg-webhook-service",
                "cnpg",
            ),
            deployment: object("apps/v1", "Deployment", "cnpg-system", "cnpg", "cnpg"),
            cluster: object("postgresql.cnpg.io/v1", "Cluster", "data", "pg", "pg"),
        }
    }

    fn webhook_reason(v: &Verdict) -> Option<(&UncheckedReason, &Option<ResourceId>)> {
        match v {
            Verdict::NotChecked {
                reason, because, ..
            } => Some((reason, because)),
            _ => None,
        }
    }

    #[test]
    fn an_unreachable_webhook_whose_service_the_deploy_writes_is_not_checked() {
        let op = operator();
        let build = [
            op.service.clone(),
            op.deployment.clone(),
            op.cluster.clone(),
        ];
        let verdicts = run(
            &build,
            &[&op.service, &op.cluster],
            &[refused(&op.cluster, 500, SERVICE_MISSING)],
        );
        assert_eq!(
            webhook_reason(&verdicts[0]),
            Some((
                &UncheckedReason::WebhookBackendWrittenByThisDeploy,
                &Some(ResourceId::from_value(&op.service))
            ))
        );
    }

    #[test]
    fn an_unreachable_webhook_whose_operator_the_deploy_writes_is_not_checked() {
        let op = operator();
        let build = [
            op.service.clone(),
            op.deployment.clone(),
            op.cluster.clone(),
        ];
        let verdicts = run(
            &build,
            &[&op.deployment, &op.cluster],
            &[refused(&op.cluster, 500, NO_ENDPOINTS)],
        );
        let Verdict::NotChecked { reason, detail, .. } = &verdicts[0] else {
            panic!("{verdicts:?}");
        };
        assert_eq!(*reason, UncheckedReason::WebhookBackendWrittenByThisDeploy);
        assert!(detail.contains("package cnpg-system/cnpg"), "{detail}");
    }

    /// The Service exists and nothing of its package changes, but the
    /// operator is down. The deploy does not repair it, so it stops before
    /// it starts.
    #[test]
    fn an_unreachable_webhook_the_deploy_does_not_repair_is_refused() {
        let op = operator();
        let build = [
            op.service.clone(),
            op.deployment.clone(),
            op.cluster.clone(),
        ];
        let verdicts = run(
            &build,
            &[&op.cluster],
            &[refused(&op.cluster, 500, NO_ENDPOINTS)],
        );
        let Verdict::Refused(Refusal::WebhookUnreachable { message, .. }) = &verdicts[0] else {
            panic!("{verdicts:?}");
        };
        assert!(message.contains("backend is down"), "{message}");
        assert!(message.contains("kix deploy prod --reconcile"), "{message}");
        assert!(message.contains("no endpoints available"), "{message}");
    }

    #[test]
    fn an_unreachable_webhook_outside_the_build_is_refused() {
        let op = operator();
        let build = [op.cluster.clone()];
        let verdicts = run(
            &build,
            &[&op.cluster],
            &[refused(&op.cluster, 500, SERVICE_MISSING)],
        );
        assert!(matches!(
            verdicts[0],
            Verdict::Refused(Refusal::WebhookUnreachable { .. })
        ));
    }

    #[test]
    fn a_denial_is_refused_and_a_webhook_without_dry_run_is_not_checked() {
        let op = operator();
        let build = [op.cluster.clone(), op.deployment.clone()];
        let verdicts = run(
            &build,
            &[&op.cluster, &op.deployment],
            &[
                refused(
                    &op.cluster,
                    400,
                    "admission webhook \"vcluster.cnpg.io\" denied the request: bad",
                ),
                refused(
                    &op.deployment,
                    400,
                    "admission webhook \"policy.example.com\" does not support dry run",
                ),
            ],
        );
        assert!(matches!(
            verdicts[0],
            Verdict::Refused(Refusal::WebhookDenied { .. })
        ));
        assert_eq!(
            webhook_reason(&verdicts[1]),
            Some((&UncheckedReason::WebhookNoDryRun, &None))
        );
    }

    #[test]
    fn a_namespace_the_deploy_creates_is_not_checked_and_named() {
        let ns = json!({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "data"}});
        let op = operator();
        let other = object("v1", "ConfigMap", "elsewhere", "c", "x");
        let build = [ns.clone(), op.cluster.clone(), other.clone()];
        let verdicts = run(
            &build,
            &[&ns, &op.cluster, &other],
            &[
                refused(&op.cluster, 404, "namespaces \"data\" not found"),
                refused(&other, 404, "namespaces \"elsewhere\" not found"),
            ],
        );
        assert_eq!(
            webhook_reason(&verdicts[0]),
            Some((
                &UncheckedReason::NamespaceCreatedByThisDeploy,
                &Some(ResourceId::from_value(&ns))
            ))
        );
        assert!(matches!(
            verdicts[1],
            Verdict::Refused(Refusal::NamespaceMissing { .. })
        ));
    }

    #[test]
    fn a_kind_whose_crd_the_deploy_creates_or_changes_is_not_checked() {
        let widget = crd("example.com", "Widget", "v2");
        let w = object("example.com/v1", "Widget", "app", "w", "app");
        let gadget_crd = crd("example.com", "Gadget", "v1");
        let g = object("example.com/v1", "Gadget", "app", "g", "app");
        let build = [widget.clone(), w.clone(), gadget_crd.clone(), g.clone()];
        let verdicts = run(
            &build,
            &[&widget, &w, &gadget_crd, &g],
            &[
                applied(&widget, Some(crd("example.com", "Widget", "v1"))),
                applied(&gadget_crd, Some(gadget_crd.clone())),
                refused(
                    &w,
                    422,
                    "Widget.example.com \"w\" is invalid: spec.size: Unsupported",
                ),
                DryRunAnswer {
                    rid: ResourceId::from_value(&g),
                    outcome: DryRunOutcome::Refused(Refusal::UnknownKind {
                        kind: "Gadget".into(),
                    }),
                },
            ],
        );
        assert_eq!(verdicts[0], Verdict::Accepted);
        assert_eq!(
            webhook_reason(&verdicts[2]),
            Some((
                &UncheckedReason::CrdChangedByThisDeploy,
                &Some(ResourceId::from_value(&widget))
            ))
        );
        assert_eq!(
            webhook_reason(&verdicts[3]),
            Some((
                &UncheckedReason::CrdCreatedByThisDeploy,
                &Some(ResourceId::from_value(&gadget_crd))
            ))
        );
    }

    #[test]
    fn an_immutable_refusal_the_engine_recreates_is_accepted_once() {
        let op = operator();
        let build = [op.deployment.clone()];
        let answers = [
            refused(
                &op.deployment,
                422,
                "Deployment.apps \"cnpg\" is invalid: spec.selector: Invalid value: field is immutable",
            ),
            DryRunAnswer {
                rid: ResourceId::from_value(&op.deployment),
                outcome: DryRunOutcome::Recreated {
                    live: None,
                    result: None,
                    not_kept: Vec::new(),
                },
            },
        ];
        assert_eq!(
            run(&build, &[&op.deployment], &answers),
            vec![Verdict::Accepted]
        );
    }

    #[test]
    fn changed_crds_ignore_an_unchanged_definition() {
        let new = crd("example.com", "Widget", "v2");
        let same = crd("example.com", "Gadget", "v1");
        let changed = ChangedCrds::of(&[
            applied(&new, Some(crd("example.com", "Widget", "v1"))),
            applied(&same, Some(same.clone())),
        ]);
        let of = |kind| json!({"apiVersion": "example.com/v1", "kind": kind});
        assert_eq!(
            changed.crd_of(&of("Widget")),
            Some(&ResourceId::from_value(&new))
        );
        assert_eq!(changed.crd_of(&of("Gadget")), None);
    }

    #[test]
    fn build_crds_match_group_and_kind() {
        let crds = BuildCrds::of(&[crd("example.com", "Widget", "v1")]);
        let widget = |api: &str| json!({"apiVersion": api, "kind": "Widget"});
        assert!(crds.brings(Some(&widget("example.com/v1"))));
        assert!(!crds.brings(Some(&widget("other.io/v1"))));
    }
}
