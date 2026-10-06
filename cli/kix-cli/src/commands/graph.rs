use miette::{IntoDiagnostic, Result};

use crate::cli::{GraphArgs, GraphFormat, OutputFormat};
use crate::output::{self, CommandResponse};

use super::CommandContext;

struct GraphResponse {
    tree: String,
    json: serde_json::Value,
}

impl CommandResponse for GraphResponse {
    fn format_text(&self) -> String {
        if self.tree.is_empty() {
            "(no resources)".to_string()
        } else {
            self.tree.clone()
        }
    }

    fn as_json(&self) -> serde_json::Value {
        self.json.clone()
    }
}

pub fn run(args: &GraphArgs, ctx: &mut CommandContext) -> Result<()> {
    let manifests = match &args.bundle {
        Some(path) => {
            let loaded = super::bundle::load(path)?;
            if loaded.bundle.cluster != args.cluster {
                return Err(miette::miette!(
                    "the bundle is a build of cluster '{}', not '{}'",
                    loaded.bundle.cluster,
                    args.cluster
                ));
            }
            let mut graph = loaded.graph()?;
            kix::manifest::stamp::stamp_annotations(&mut graph);
            let mut manifests: Vec<serde_json::Value> =
                graph.resources.into_values().map(|r| r.manifest).collect();
            manifests.sort_by_cached_key(kix::eval::cli_backend::manifest_sort_key);
            manifests
        }
        None => ctx.eval_cluster_or_suggest(&args.cluster)?.raw_manifests,
    };

    let graph = kix::cluster::graph::ResourceGraph::from_manifests(&manifests).into_diagnostic()?;

    // --format takes priority over global -o
    match args.format {
        Some(GraphFormat::Dot) => {
            print!("{}", graph.to_dot());
        }
        Some(GraphFormat::Json) => {
            let json = graph.to_json();
            println!("{}", serde_json::to_string_pretty(&json).into_diagnostic()?);
        }
        Some(GraphFormat::Tree) => {
            let tree = graph.to_tree();
            if tree.is_empty() {
                println!("(no resources)");
            } else {
                print!("{tree}");
            }
        }
        None => {
            let response = GraphResponse {
                tree: graph.to_tree(),
                json: graph.to_json(),
            };
            println!(
                "{}",
                output::render(&response, ctx.output_format(OutputFormat::Text))?
            );
        }
    }

    if !ctx.global.quiet {
        eprintln!(
            "{} resources, {} dependencies",
            graph.node_count(),
            graph.edge_count()
        );
    }

    Ok(())
}
