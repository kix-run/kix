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

/// Convert scorecard findings to SARIF 2.1.0 JSON.
fn to_sarif(scorecard_report: &serde_json::Value) -> serde_json::Value {
    let findings = scorecard_report
        .get("findings")
        .and_then(|f| f.as_array())
        .cloned()
        .unwrap_or_default();

    // Collect unique rules
    let mut rules: Vec<serde_json::Value> = Vec::new();
    let mut rule_indices: std::collections::HashMap<String, usize> =
        std::collections::HashMap::new();

    for finding in &findings {
        let rule_id = finding
            .get("rule")
            .and_then(|r| r.as_str())
            .unwrap_or("unknown");
        if !rule_indices.contains_key(rule_id) {
            let idx = rules.len();
            rule_indices.insert(rule_id.to_string(), idx);
            rules.push(serde_json::json!({
                "id": rule_id,
                "shortDescription": { "text": rule_id },
                "defaultConfiguration": {
                    "level": match finding.get("severity").and_then(|s| s.as_str()) {
                        Some("error") => "error",
                        Some("warning") => "warning",
                        _ => "note"
                    }
                },
                "properties": {
                    "tags": finding.get("tags").cloned().unwrap_or(serde_json::json!([]))
                }
            }));
        }
    }

    // Convert findings to SARIF results
    let results: Vec<serde_json::Value> = findings
        .iter()
        .map(|f| {
            let rule_id = f.get("rule").and_then(|r| r.as_str()).unwrap_or("unknown");
            let severity = f
                .get("severity")
                .and_then(|s| s.as_str())
                .unwrap_or("warning");
            let level = match severity {
                "error" => "error",
                "warning" => "warning",
                _ => "note",
            };
            let message = f
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("check failed");
            let namespace = f.get("namespace").and_then(|n| n.as_str());
            let instance = f.get("instance").and_then(|i| i.as_str());
            let resource = f.get("resource").and_then(|r| r.as_str());

            let location_text = [namespace, instance, resource]
                .iter()
                .filter_map(|s| *s)
                .collect::<Vec<_>>()
                .join("/");

            let mut result = serde_json::json!({
                "ruleId": rule_id,
                "ruleIndex": rule_indices.get(rule_id).copied().unwrap_or(0),
                "level": level,
                "message": { "text": message }
            });

            // Add location if we have context
            if !location_text.is_empty() {
                result["locations"] = serde_json::json!([{
                    "logicalLocations": [{
                        "fullyQualifiedName": location_text,
                        "kind": f.get("level").and_then(|l| l.as_str()).unwrap_or("module")
                    }]
                }]);
            }

            result
        })
        .collect();

    serde_json::json!({
        "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
        "version": "2.1.0",
        "runs": [{
            "tool": {
                "driver": {
                    "name": "kix",
                    "informationUri": "https://kix.dev",
                    "rules": rules
                }
            },
            "results": results
        }]
    })
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

    // Step 3: Include scorecard findings
    if let Some(output) = &cluster_output {
        if let Some(report) = &output.scorecard_report {
            if let Some(findings) = report.get("findings").and_then(|f| f.as_array()) {
                let errors = findings
                    .iter()
                    .filter(|f| f.get("severity").and_then(|s| s.as_str()) == Some("error"))
                    .count();
                let warnings = findings
                    .iter()
                    .filter(|f| f.get("severity").and_then(|s| s.as_str()) == Some("warning"))
                    .count();
                let infos = findings
                    .iter()
                    .filter(|f| f.get("severity").and_then(|s| s.as_str()) == Some("info"))
                    .count();

                let result_str = if errors > 0 { "fail" } else { "pass" };
                results.push(CheckResult {
                    tool: "scorecard".into(),
                    result: result_str.into(),
                    details: format!("{} errors, {} warnings, {} info", errors, warnings, infos),
                });
            }
        } else {
            results.push(CheckResult {
                tool: "scorecard".into(),
                result: "skip".into(),
                details: "scorecard not enabled in cluster definition".into(),
            });
        }
    }

    // Determine exit code
    let has_failure = results.iter().any(|r| r.result == "fail");

    // SARIF output: print SARIF JSON and exit instead of normal output
    if args.sarif {
        let sarif = if let Some(output) = &cluster_output {
            if let Some(report) = &output.scorecard_report {
                to_sarif(report)
            } else {
                // No scorecard data — emit empty SARIF run
                to_sarif(&serde_json::json!({"findings": []}))
            }
        } else {
            // Eval failed — emit empty SARIF run
            to_sarif(&serde_json::json!({"findings": []}))
        };

        println!(
            "{}",
            serde_json::to_string_pretty(&sarif).expect("SARIF serialization should not fail")
        );

        if has_failure {
            std::process::exit(1);
        }
        return Ok(());
    }

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
