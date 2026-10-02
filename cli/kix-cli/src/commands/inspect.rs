use std::collections::BTreeMap;

use miette::Result;

use crate::cli::{InspectArgs, OutputFormat};
use crate::output::{self, CommandResponse};
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId};

use super::CommandContext;

struct InspectResponse {
    cluster_name: String,
    total_resources: usize,
    by_namespace: BTreeMap<String, Vec<ResourceId>>,
    kind_counts: BTreeMap<String, usize>,
}

impl CommandResponse for InspectResponse {
    fn format_text(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!("Cluster: {}\n", self.cluster_name));
        out.push_str(&format!("Total resources: {}\n\n", self.total_resources));

        // Namespaces
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

        // Kind breakdown
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

        // Resource listing by namespace
        out.push_str("Resources:\n");
        for (ns, resources) in &self.by_namespace {
            let ns_display = if ns == CLUSTER_SCOPED {
                "(cluster-scoped)"
            } else {
                ns.as_str()
            };
            out.push_str(&format!("  {}:\n", ns_display));
            let mut sorted = resources.clone();
            sorted.sort_by(|a, b| a.kind.cmp(&b.kind).then(a.name.cmp(&b.name)));
            for rid in sorted {
                out.push_str(&format!("    {}/{}\n", rid.kind, rid.name));
            }
        }

        out.trim_end().to_string()
    }

    fn as_json(&self) -> serde_json::Value {
        serde_json::json!({
            "cluster": self.cluster_name,
            "totalResources": self.total_resources,
            "namespaces": self.by_namespace.iter().map(|(ns, resources)| {
                serde_json::json!({
                    "name": ns,
                    "resources": resources.iter().map(|r| {
                        serde_json::json!({
                            "kind": r.kind,
                            "name": r.name,
                        })
                    }).collect::<Vec<_>>(),
                })
            }).collect::<Vec<_>>(),
            "kindCounts": self.kind_counts,
        })
    }
}

pub fn run(args: &InspectArgs, ctx: &mut CommandContext) -> Result<()> {
    let cluster = ctx.eval_cluster_or_suggest(&args.cluster)?;

    let manifests = &cluster.raw_manifests;

    // Group resources by namespace and kind
    let mut by_namespace: BTreeMap<String, Vec<ResourceId>> = BTreeMap::new();
    let mut kind_counts: BTreeMap<String, usize> = BTreeMap::new();

    for manifest in manifests {
        let rid = ResourceId::from_value(manifest);
        by_namespace
            .entry(rid.namespace.clone())
            .or_default()
            .push(rid.clone());
        *kind_counts.entry(rid.kind.clone()).or_default() += 1;
    }

    let response = InspectResponse {
        cluster_name: cluster.cluster_name().unwrap_or(&args.cluster).to_string(),
        total_resources: manifests.len(),
        by_namespace,
        kind_counts,
    };

    let format = ctx.output_format(OutputFormat::Text);
    let rendered = output::render(&response, format)?;
    println!("{rendered}");

    Ok(())
}
