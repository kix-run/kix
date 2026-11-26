use std::collections::BTreeMap;

use miette::Result;

use crate::cli::ListResourcesArgs;
use crate::output::{self, CommandResponse};
use kix::manifest::keys;
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId};

use crate::commands::CommandContext;

/// A cluster's rendered resources by namespace and kind.
#[derive(serde::Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct InspectResponse {
    #[serde(rename = "cluster")]
    cluster_name: String,
    total_resources: usize,
    /// The namespaces in name order. `_cluster` holds cluster-scoped
    /// resources.
    #[serde(rename = "namespaces", serialize_with = "namespaces")]
    #[schemars(with = "Vec<InspectNamespace>")]
    by_namespace: BTreeMap<String, Vec<ResourceId>>,
    /// The number of resources of each kind, keyed `Kind.group`, or `Kind`
    /// for the core group.
    kind_counts: BTreeMap<String, usize>,
    /// The ServiceAccounts that carry a cloud identity, in namespace and
    /// name order. Each is a subject that the cloud side must trust or bind.
    cloud_identities: Vec<CloudIdentity>,
}

/// A ServiceAccount with a cloud identity, read from the cloud identity
/// record Kix writes on it.
#[derive(serde::Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
struct CloudIdentity {
    namespace: String,
    service_account: String,
    /// `aws`, `gcp`, or `azure`.
    cloud: String,
    /// How the cluster delivers the identity: `irsa`, `eks-pod-identity`,
    /// `gke`, or `azure-workload-id`.
    mechanism: String,
    /// The identity's fields as the definition gives them, such as
    /// `roleArn` for AWS, `serviceAccount` for Google Cloud (absent when
    /// roles are granted to the Kubernetes ServiceAccount itself), or
    /// `clientId` and `tenantId` for Azure.
    identity: serde_json::Map<String, serde_json::Value>,
    /// The ServiceAccount in the form its cloud accepts for this identity:
    /// the `sub` of an IRSA trust policy or the subject of an Azure federated
    /// credential (`system:serviceaccount:<namespace>:<name>`), the member
    /// of a `roles/iam.workloadIdentityUser` binding for a Google service
    /// account (`serviceAccount:<project-id>.svc.id.goog[<namespace>/<name>]`),
    /// or the principal of a direct Google grant
    /// (`principal://iam.googleapis.com/...`). Null for EKS Pod Identity,
    /// whose association takes `namespace` and `serviceAccount` as two
    /// fields.
    subject: Option<String>,
    /// The placeholders in `subject` for values Kix does not know, such as
    /// `<project-id>` and `<project-number>` of the Google Cloud project
    /// that holds the cluster's workload identity pool. Replace each before
    /// use.
    subject_placeholders: Vec<String>,
    /// `system:serviceaccount:<namespace>:<name>`, the subject of the
    /// ServiceAccount's Kubernetes token, on every cloud.
    kubernetes_subject: String,
    /// The principal the role's trust policy must name when Kix knows it:
    /// `pods.eks.amazonaws.com` for EKS Pod Identity. Null otherwise.
    trust_principal: Option<String>,
}

/// The service principal an EKS Pod Identity role must trust.
const POD_IDENTITY_PRINCIPAL: &str = "pods.eks.amazonaws.com";

/// Placeholders for the Google Cloud project that holds the cluster's
/// workload identity pool, which the cluster definition does not name.
const PROJECT_ID: &str = "<project-id>";
const PROJECT_NUMBER: &str = "<project-number>";

/// Return the subject in the form `cloud` and `mechanism` accept for
/// `identity`, and the placeholders it holds.
fn cloud_subject(
    cloud: &str,
    mechanism: &str,
    identity: &serde_json::Map<String, serde_json::Value>,
    namespace: &str,
    name: &str,
) -> (Option<String>, Vec<String>) {
    match (cloud, mechanism) {
        ("aws", "eks-pod-identity") => (None, Vec::new()),
        ("gcp", _) if identity.contains_key("serviceAccount") => (
            Some(format!(
                "serviceAccount:{PROJECT_ID}.svc.id.goog[{namespace}/{name}]"
            )),
            vec![PROJECT_ID.to_string()],
        ),
        ("gcp", _) => (
            Some(format!(
                "principal://iam.googleapis.com/projects/{PROJECT_NUMBER}/locations/global/workloadIdentityPools/{PROJECT_ID}.svc.id.goog/subject/ns/{namespace}/sa/{name}"
            )),
            vec![PROJECT_NUMBER.to_string(), PROJECT_ID.to_string()],
        ),
        _ => (
            Some(format!("system:serviceaccount:{namespace}:{name}")),
            Vec::new(),
        ),
    }
}

/// Return the cloud identity a ServiceAccount manifest records, or `None`.
fn cloud_identity_of(manifest: &serde_json::Value, rid: &ResourceId) -> Option<CloudIdentity> {
    if rid.kind != "ServiceAccount" || !rid.group.is_empty() {
        return None;
    }
    let record: serde_json::Value =
        serde_json::from_str(keys::get(manifest, keys::CLOUD_IDENTITY)?).ok()?;
    let mechanism = record.get("mechanism")?.as_str()?.to_string();
    let (cloud, identity) = record.as_object()?.iter().find_map(|(k, v)| {
        (k != "mechanism").then(|| Some((k.clone(), v.as_object()?.clone())))
    })??;
    let (subject, subject_placeholders) =
        cloud_subject(&cloud, &mechanism, &identity, &rid.namespace, &rid.name);
    Some(CloudIdentity {
        subject,
        subject_placeholders,
        kubernetes_subject: format!("system:serviceaccount:{}:{}", rid.namespace, rid.name),
        trust_principal: (mechanism == "eks-pod-identity")
            .then(|| POD_IDENTITY_PRINCIPAL.to_string()),
        namespace: rid.namespace.clone(),
        service_account: rid.name.clone(),
        cloud,
        mechanism,
        identity,
    })
}

/// One namespace of [`InspectResponse`], as JSON shows it.
#[derive(serde::Serialize, schemars::JsonSchema)]
struct InspectNamespace {
    name: String,
    resources: Vec<InspectResource>,
}

#[derive(serde::Serialize, schemars::JsonSchema)]
struct InspectResource {
    kind: String,
    /// The kind's API group. Left out for the core group.
    #[serde(skip_serializing_if = "String::is_empty")]
    group: String,
    name: String,
}

fn namespaces<S: serde::Serializer>(
    by_namespace: &BTreeMap<String, Vec<ResourceId>>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    serializer.collect_seq(by_namespace.iter().map(|(ns, resources)| {
        InspectNamespace {
            name: ns.clone(),
            resources: resources
                .iter()
                .map(|r| InspectResource {
                    kind: r.kind.clone(),
                    group: r.group.clone(),
                    name: r.name.clone(),
                })
                .collect(),
        }
    }))
}

impl CommandResponse for InspectResponse {
    fn text(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!("Cluster: {}\n", self.cluster_name));
        out.push_str(&format!("Total resources: {}\n\n", self.total_resources));

        out.push_str(&format!("Namespaces ({}):\n", self.by_namespace.len()));
        for (ns, resources) in &self.by_namespace {
            let ns_display = if ns == CLUSTER_SCOPED {
                "(cluster-scoped)"
            } else {
                ns
            };
            out.push_str(&format!(
                "  {} ({} resources)\n",
                ns_display,
                resources.len()
            ));
        }
        out.push('\n');

        out.push_str("Resource kinds:\n");
        let mut table = comfy_table::Table::new();
        table.load_preset(comfy_table::presets::NOTHING);
        table.set_header(["Kind", "Count"]);
        let mut kinds: Vec<_> = self.kind_counts.iter().collect();
        kinds.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
        for (kind, count) in kinds {
            table.add_row([kind.as_str(), &count.to_string()]);
        }
        out.push_str(&table.to_string());
        out.push_str("\n\n");

        out.push_str("Resources:\n");
        for (ns, resources) in &self.by_namespace {
            let ns_display = if ns == CLUSTER_SCOPED {
                "(cluster-scoped)"
            } else {
                ns.as_str()
            };
            out.push_str(&format!("  {}:\n", ns_display));
            let mut sorted = resources.clone();
            sorted.sort_by(|a, b| (&a.kind, &a.group, &a.name).cmp(&(&b.kind, &b.group, &b.name)));
            for rid in sorted {
                let kind = kix::manifest::types::qualified_kind(&rid.group, &rid.kind);
                out.push_str(&format!("    {kind}/{}\n", rid.name));
            }
        }

        if !self.cloud_identities.is_empty() {
            out.push_str("\n\nCloud identities:\n");
            let mut table = comfy_table::Table::new();
            table.load_preset(comfy_table::presets::NOTHING);
            table.set_header(["Subject", "Mechanism", "Identity"]);
            for id in &self.cloud_identities {
                let identity = if id.identity.is_empty() {
                    "Kubernetes ServiceAccount".to_string()
                } else {
                    id.identity
                        .iter()
                        .map(|(k, v)| format!("{k}={}", v.as_str().unwrap_or_default()))
                        .collect::<Vec<_>>()
                        .join(" ")
                };
                let subject = id.subject.clone().unwrap_or_else(|| {
                    format!(
                        "association for {}/{}, role trusts {}",
                        id.namespace,
                        id.service_account,
                        id.trust_principal.as_deref().unwrap_or("?")
                    )
                });
                table.add_row([subject.as_str(), id.mechanism.as_str(), &identity]);
            }
            out.push_str(&table.to_string());
            if self
                .cloud_identities
                .iter()
                .any(|id| !id.subject_placeholders.is_empty())
            {
                out.push_str(&format!(
                    "\n{PROJECT_ID} and {PROJECT_NUMBER} stand for the ID and the number of the Google Cloud project that holds the cluster. Replace them before you use a subject.\n"
                ));
            }
        }

        out.trim_end().to_string()
    }
}

pub fn run(args: &ListResourcesArgs, ctx: &mut CommandContext) -> Result<()> {
    let cluster = ctx.eval_cluster_or_suggest(&args.cluster)?;

    let manifests = &cluster.raw_manifests;

    let mut by_namespace: BTreeMap<String, Vec<ResourceId>> = BTreeMap::new();
    let mut kind_counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut cloud_identities = Vec::new();

    for manifest in manifests {
        let rid = ResourceId::from_value(manifest);
        cloud_identities.extend(cloud_identity_of(manifest, &rid));
        by_namespace
            .entry(rid.namespace.clone())
            .or_default()
            .push(rid.clone());
        *kind_counts
            .entry(kix::manifest::types::qualified_kind(&rid.group, &rid.kind))
            .or_default() += 1;
    }

    cloud_identities.sort_by(|a: &CloudIdentity, b| {
        (&a.namespace, &a.service_account).cmp(&(&b.namespace, &b.service_account))
    });
    let response = InspectResponse {
        cluster_name: cluster.cluster_name().unwrap_or(&args.cluster).to_string(),
        total_resources: manifests.len(),
        by_namespace,
        kind_counts,
        cloud_identities,
    };

    output::result(&response)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn service_account(name: &str, record: Option<serde_json::Value>) -> serde_json::Value {
        let mut m = json!({
            "apiVersion": "v1",
            "kind": "ServiceAccount",
            "metadata": { "name": name, "namespace": "external-dns" }
        });
        if let Some(r) = record {
            m["metadata"]["annotations"] = json!({ keys::CLOUD_IDENTITY: r.to_string() });
        }
        m
    }

    #[test]
    fn a_bound_service_account_gives_its_subject() {
        let m = service_account(
            "route53",
            Some(json!({
                "mechanism": "irsa",
                "aws": { "roleArn": "arn:aws:iam::111122223333:role/external-dns" }
            })),
        );
        let id = cloud_identity_of(&m, &ResourceId::from_value(&m)).expect("bound");
        assert_eq!(
            id.subject.as_deref(),
            Some("system:serviceaccount:external-dns:route53")
        );
        assert!(id.subject_placeholders.is_empty());
        assert_eq!(
            id.kubernetes_subject,
            "system:serviceaccount:external-dns:route53"
        );
        assert_eq!(id.cloud, "aws");
        assert_eq!(id.mechanism, "irsa");
        assert_eq!(
            id.identity.get("roleArn").and_then(|v| v.as_str()),
            Some("arn:aws:iam::111122223333:role/external-dns")
        );
    }

    #[test]
    fn an_unbound_service_account_or_other_kind_gives_none() {
        let plain = service_account("plain", None);
        assert!(cloud_identity_of(&plain, &ResourceId::from_value(&plain)).is_none());
        let mut config_map =
            service_account("route53", Some(json!({ "mechanism": "gke", "gcp": {} })));
        config_map["kind"] = json!("ConfigMap");
        assert!(cloud_identity_of(&config_map, &ResourceId::from_value(&config_map)).is_none());
    }

    #[test]
    fn text_lists_each_subject() {
        let m = service_account("dns", Some(json!({ "mechanism": "gke", "gcp": {} })));
        let rid = ResourceId::from_value(&m);
        let response = InspectResponse {
            cluster_name: "c".into(),
            total_resources: 1,
            by_namespace: BTreeMap::from([(rid.namespace.clone(), vec![rid.clone()])]),
            kind_counts: BTreeMap::from([("ServiceAccount".into(), 1)]),
            cloud_identities: cloud_identity_of(&m, &rid).into_iter().collect(),
        };
        let text = response.text();
        assert!(
            text.contains("principal://iam.googleapis.com/projects/<project-number>/locations/global/workloadIdentityPools/<project-id>.svc.id.goog/subject/ns/external-dns/sa/dns"),
            "{text}"
        );
        assert!(text.contains("Kubernetes ServiceAccount"), "{text}");
        assert!(
            text.contains("<project-id> and <project-number> stand for the ID and the number of the Google Cloud project that holds the cluster."),
            "{text}"
        );
    }
}

#[cfg(test)]
mod subject_tests {
    use super::*;
    use serde_json::json;

    fn fields(v: serde_json::Value) -> serde_json::Map<String, serde_json::Value> {
        v.as_object().unwrap().clone()
    }

    // Each cloud gets the form it accepts, with placeholders only for the
    // Google project, which Kix does not know.
    #[test]
    fn each_cloud_gets_its_own_form() {
        let linked = cloud_subject(
            "gcp",
            "gke",
            &fields(json!({ "serviceAccount": "dns@p.iam.gserviceaccount.com" })),
            "ns",
            "sa",
        );
        assert_eq!(
            linked,
            (
                Some("serviceAccount:<project-id>.svc.id.goog[ns/sa]".to_string()),
                vec!["<project-id>".to_string()]
            )
        );
        let direct = cloud_subject("gcp", "gke", &fields(json!({})), "ns", "sa");
        assert_eq!(direct.1, vec!["<project-number>", "<project-id>"]);
        assert!(direct.0.unwrap().ends_with("/subject/ns/ns/sa/sa"));
        let azure = cloud_subject(
            "azure",
            "azure-workload-id",
            &fields(json!({ "clientId": "x" })),
            "ns",
            "sa",
        );
        assert_eq!(
            azure,
            (Some("system:serviceaccount:ns:sa".to_string()), vec![])
        );
        let pod_identity = cloud_subject(
            "aws",
            "eks-pod-identity",
            &fields(json!({ "roleArn": "r" })),
            "ns",
            "sa",
        );
        assert_eq!(pod_identity, (None, vec![]));
    }

    // Under EKS Pod Identity the cloud side needs an association and a
    // role that trusts the EKS service principal, never a token subject.
    #[test]
    fn pod_identity_names_the_association_and_principal() {
        let m = json!({
            "apiVersion": "v1",
            "kind": "ServiceAccount",
            "metadata": {
                "name": "route53",
                "namespace": "external-dns",
                "annotations": { keys::CLOUD_IDENTITY: json!({
                    "mechanism": "eks-pod-identity",
                    "aws": { "roleArn": "arn:aws:iam::111122223333:role/dns" }
                }).to_string() }
            }
        });
        let rid = ResourceId::from_value(&m);
        let id = cloud_identity_of(&m, &rid).expect("bound");
        assert_eq!(id.subject, None);
        assert_eq!(
            id.trust_principal.as_deref(),
            Some("pods.eks.amazonaws.com")
        );
        let response = InspectResponse {
            cluster_name: "c".into(),
            total_resources: 1,
            by_namespace: BTreeMap::from([(rid.namespace.clone(), vec![rid.clone()])]),
            kind_counts: BTreeMap::from([("ServiceAccount".into(), 1)]),
            cloud_identities: vec![id],
        };
        let text = response.text();
        assert!(
            text.contains(
                "association for external-dns/route53, role trusts pods.eks.amazonaws.com"
            ),
            "{text}"
        );
        assert!(!text.contains("<project-id>"), "{text}");
    }
}
