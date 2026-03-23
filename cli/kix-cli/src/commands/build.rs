use std::io::IsTerminal;

use miette::{IntoDiagnostic, Result};

use crate::cli::{BuildArgs, OutputFormat};
use crate::output::{self, CommandResponse};

use super::CommandContext;

struct BuildResponse {
    manifests: Vec<serde_json::Value>,
}

impl CommandResponse for BuildResponse {
    fn format_text(&self) -> String {
        kix_manifest::serialize::manifests_to_yaml(&self.manifests)
    }

    fn as_json(&self) -> serde_json::Value {
        serde_json::Value::Array(self.manifests.clone())
    }
}

pub fn run(args: &BuildArgs, ctx: &mut CommandContext) -> Result<()> {
    // Show spinner if on a TTY and not quiet
    let spinner = if std::io::stderr().is_terminal() && !ctx.global.quiet {
        let sp = indicatif::ProgressBar::new_spinner();
        sp.set_style(
            indicatif::ProgressStyle::default_spinner()
                .template("{spinner:.cyan} {msg}")
                .expect("valid template"),
        );
        sp.set_message(format!("Evaluating cluster '{}'...", args.cluster));
        sp.enable_steady_tick(std::time::Duration::from_millis(80));
        Some(sp)
    } else {
        None
    };

    let result = ctx.evaluator.eval_cluster(&args.cluster);

    if let Some(sp) = &spinner {
        sp.finish_and_clear();
    }

    let cluster_output = match result {
        Ok(o) => o,
        Err(kix_eval::error::KixEvalError::ClusterNotFound { name }) => {
            let clusters = ctx.evaluator.list_clusters().unwrap_or_default();
            let mut msg = format!("cluster '{}' not found", name);
            if !clusters.is_empty() {
                msg.push_str(&format!(". Available clusters: {}", clusters.join(", ")));
            }
            return Err(miette::miette!("{}", msg));
        }
        Err(e) => return Err(e).into_diagnostic(),
    };

    let response = BuildResponse {
        manifests: cluster_output.raw_manifests,
    };

    // Build defaults to YAML; both Text and Yaml use multi-document YAML format
    match ctx.output_format(OutputFormat::Yaml) {
        OutputFormat::Yaml | OutputFormat::Text => {
            print!("{}", response.format_text());
        }
        OutputFormat::Json => {
            println!("{}", output::render(&response, OutputFormat::Json));
        }
    }

    Ok(())
}
