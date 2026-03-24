use miette::{IntoDiagnostic, Result};

use crate::cli::{ListArgs, OutputFormat};
use crate::output::{self, CommandResponse};

use super::CommandContext;

struct ListResponse {
    clusters: Vec<String>,
}

impl CommandResponse for ListResponse {
    fn format_text(&self) -> String {
        let mut table = comfy_table::Table::new();
        table.load_preset(comfy_table::presets::NOTHING);
        table.set_header(["NAME"]);
        for c in &self.clusters {
            table.add_row([c]);
        }
        table.to_string()
    }

    fn as_json(&self) -> serde_json::Value {
        serde_json::json!(self.clusters)
    }
}

pub fn run(_args: &ListArgs, ctx: &mut CommandContext) -> Result<()> {
    let clusters = ctx.evaluator.list_clusters().into_diagnostic()?;

    if clusters.is_empty() {
        eprintln!("No clusters found in this flake.");
        return Ok(());
    }

    let response = ListResponse { clusters };
    println!(
        "{}",
        output::render(&response, ctx.output_format(OutputFormat::Text))?
    );

    Ok(())
}
