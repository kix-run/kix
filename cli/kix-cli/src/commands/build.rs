use miette::Result;

use crate::cli::{BuildArgs, OutputFormat};
use crate::output::{self, CommandResponse};

use super::CommandContext;

struct BuildResponse {
    manifests: Vec<serde_json::Value>,
}

impl CommandResponse for BuildResponse {
    fn format_text(&self) -> String {
        kix::manifest::serialize::manifests_to_yaml(&self.manifests)
            .expect("YAML serialization of valid manifests should not fail")
    }

    fn as_json(&self) -> serde_json::Value {
        serde_json::Value::Array(self.manifests.clone())
    }
}

pub fn run(args: &BuildArgs, ctx: &mut CommandContext) -> Result<()> {
    let spinner = output::spinner(format!("Evaluating cluster '{}'...", args.cluster));

    let cluster_output = ctx.eval_cluster_or_suggest(&args.cluster);

    if let Some(sp) = &spinner {
        sp.finish_and_clear();
    }

    let cluster_output = cluster_output?;

    let response = BuildResponse {
        manifests: cluster_output.raw_manifests,
    };

    // Build defaults to YAML; both Text and Yaml use multi-document YAML format
    match output::format() {
        OutputFormat::Yaml | OutputFormat::Text | OutputFormat::Markdown => {
            print!("{}", response.format_text());
        }
        OutputFormat::Json => output::result(&response)?,
    }

    Ok(())
}
