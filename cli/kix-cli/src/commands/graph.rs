use miette::{IntoDiagnostic, Result};

use crate::cli::{GraphArgs, OutputFormat};
use crate::output::{self, CommandResponse};

use super::CommandContext;

/// The dependency graph of a cluster's resources. JSON and YAML print the
/// graph's nodes and edges.
#[derive(serde::Serialize, schemars::JsonSchema)]
#[serde(transparent)]
pub(crate) struct GraphResponse {
    listing: kix::cluster::graph::GraphListing,
    #[serde(skip)]
    #[schemars(skip)]
    tree: String,
    #[serde(skip)]
    #[schemars(skip)]
    dot: String,
}

impl CommandResponse for GraphResponse {
    fn text(&self) -> String {
        if self.tree.is_empty() {
            "(no resources)".to_string()
        } else {
            self.tree.clone()
        }
    }

    fn render(&self, format: OutputFormat) -> Result<String> {
        match format {
            OutputFormat::Tree => Ok(self.text()),
            OutputFormat::Dot => Ok(self.dot.clone()),
            other => output::render(self, other),
        }
    }
}

pub fn run(args: &GraphArgs, ctx: &mut CommandContext) -> Result<()> {
    let manifests = match &args.bundle {
        Some(path) => {
            let build = super::read_bundle(path, &[], &args.cluster)?;
            let mut manifests: Vec<serde_json::Value> = build
                .graph()
                .resources
                .values()
                .map(|r| r.manifest.clone())
                .collect();
            manifests.sort_by_cached_key(kix::eval::cli_backend::manifest_sort_key);
            manifests
        }
        None => ctx.eval_cluster_or_suggest(&args.cluster)?.raw_manifests,
    };

    let graph = kix::cluster::graph::ResourceGraph::from_manifests(&manifests).into_diagnostic()?;

    output::result(&GraphResponse {
        listing: graph.listing(),
        tree: graph.to_tree(),
        dot: graph.to_dot(),
    })?;

    crate::esay!(
        "{} resources, {} dependencies",
        graph.node_count(),
        graph.edge_count()
    );

    Ok(())
}
