use std::collections::BTreeMap;

use miette::Result;

use crate::cli::ListResourcesArgs;
use crate::output::{self, CommandResponse};
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

        out.trim_end().to_string()
    }
}

pub fn run(args: &ListResourcesArgs, ctx: &mut CommandContext) -> Result<()> {
    let cluster = ctx.eval_cluster_or_suggest(&args.cluster)?;

    let manifests = &cluster.raw_manifests;

    let mut by_namespace: BTreeMap<String, Vec<ResourceId>> = BTreeMap::new();
    let mut kind_counts: BTreeMap<String, usize> = BTreeMap::new();

    for manifest in manifests {
        let rid = ResourceId::from_value(manifest);
        by_namespace
            .entry(rid.namespace.clone())
            .or_default()
            .push(rid.clone());
        *kind_counts
            .entry(kix::manifest::types::qualified_kind(&rid.group, &rid.kind))
            .or_default() += 1;
    }

    let response = InspectResponse {
        cluster_name: cluster.cluster_name().unwrap_or(&args.cluster).to_string(),
        total_resources: manifests.len(),
        by_namespace,
        kind_counts,
    };

    output::result(&response)
}
