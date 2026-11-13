use miette::Result;

use crate::cli::{BuildArgs, OutputFormat};
use crate::output::{self, CommandResponse};

use super::CommandContext;

/// The cluster's manifests. JSON is one array, and YAML is one document per
/// manifest, as `kubectl apply -f` reads it.
#[derive(serde::Serialize, schemars::JsonSchema)]
#[serde(transparent)]
pub(crate) struct BuildResponse {
    /// Kubernetes objects.
    manifests: Vec<serde_json::Value>,
}

impl CommandResponse for BuildResponse {
    fn text(&self) -> String {
        kix::manifest::serialize::manifests_to_yaml(&self.manifests)
            .expect("YAML serialization of valid manifests should not fail")
    }

    fn render(&self, format: OutputFormat) -> Result<String> {
        match format {
            OutputFormat::Yaml => Ok(self.text()),
            other => output::render(self, other),
        }
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

    output::result(&response)
}
