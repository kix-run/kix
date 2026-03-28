use std::io::IsTerminal;

use miette::{IntoDiagnostic, Result};

use crate::cli::{CheckArgs, OutputFormat};
use crate::output::{self, CommandResponse};
use kix::manifest::validate::{PreflightResult, default_tools, run_preflight};

use super::CommandContext;

#[derive(serde::Serialize)]
struct CheckResult {
    tool: String,
    result: String,
    details: String,
}

impl From<&PreflightResult> for CheckResult {
    fn from(pr: &PreflightResult) -> Self {
        let result = if pr.passed { "pass" } else { "fail" };
        CheckResult {
            tool: pr.tool.clone(),
            result: result.into(),
            details: pr.details.clone(),
        }
    }
}

struct CheckResponse {
    results: Vec<CheckResult>,
}

impl CommandResponse for CheckResponse {
    fn format_text(&self) -> String {
        let mut table = comfy_table::Table::new();
        table.load_preset(comfy_table::presets::NOTHING);
        table.set_header(["TOOL", "RESULT", "DETAILS"]);
        for r in &self.results {
            table.add_row([&r.tool, &r.result, &r.details]);
        }
        table.to_string()
    }

    fn as_json(&self) -> serde_json::Value {
        serde_json::to_value(&self.results).unwrap_or_default()
    }
}

pub fn run(args: &CheckArgs, ctx: &mut CommandContext) -> Result<()> {
    let mut results: Vec<CheckResult> = Vec::new();

    // Show spinner if TTY
    let spinner = if std::io::stderr().is_terminal() && !ctx.global.quiet {
        let sp = indicatif::ProgressBar::new_spinner();
        sp.set_style(
            indicatif::ProgressStyle::default_spinner()
                .template("{spinner:.cyan} {msg}")
                .expect("valid template"),
        );
        sp.set_message(format!("Checking cluster '{}'...", args.cluster));
        sp.enable_steady_tick(std::time::Duration::from_millis(80));
        Some(sp)
    } else {
        None
    };

    // Step 1: Nix evaluation (cross-resource validation happens during eval)
    let eval_result = ctx.evaluator.eval_cluster(&args.cluster);

    if let Some(sp) = &spinner {
        sp.finish_and_clear();
    }

    let cluster_output = match eval_result {
        Ok(output) => {
            results.push(CheckResult {
                tool: "eval".into(),
                result: "pass".into(),
                details: format!("{} manifests evaluated", output.raw_manifests.len()),
            });
            Some(output)
        }
        Err(kix::eval::error::KixEvalError::ClusterNotFound { name }) => {
            return Err(miette::miette!("cluster '{}' not found", name));
        }
        Err(e) => {
            results.push(CheckResult {
                tool: "eval".into(),
                result: "fail".into(),
                details: e.to_string(),
            });
            None
        }
    };

    // Step 2: Run preflight tools against rendered manifests
    if let Some(output) = &cluster_output {
        // Write manifests to a temp dir for preflight tools
        let tmp_dir = tempfile::tempdir().into_diagnostic()?;
        kix::manifest::serialize::write_manifests_to_dir(&output.raw_manifests, tmp_dir.path())
            .map_err(|e| miette::miette!("failed to write manifests: {e}"))?;

        let tools = default_tools();
        let tool_refs: Vec<&dyn kix::manifest::validate::PreflightTool> =
            tools.iter().map(|t| t.as_ref()).collect();
        let preflight_results = run_preflight(tmp_dir.path(), &tool_refs);

        for pr in &preflight_results {
            results.push(CheckResult::from(pr));
        }
    }

    // Determine exit code
    let has_failure = results.iter().any(|r| r.result == "fail");

    let response = CheckResponse { results };
    println!(
        "{}",
        output::render(&response, ctx.output_format(OutputFormat::Text))?
    );

    if has_failure {
        std::process::exit(1);
    }

    Ok(())
}
