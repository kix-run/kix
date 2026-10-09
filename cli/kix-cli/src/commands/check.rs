use std::io::IsTerminal;

use miette::Result;

use crate::cli::CheckArgs;
use crate::output::{self, CommandResponse};

use super::CommandContext;
use kix::manifest::keys;

#[derive(serde::Serialize)]
struct CheckResult {
    tool: String,
    result: String,
    details: String,
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
                    "informationUri": keys::WEBSITE,
                    "rules": rules
                }
            },
            "results": results
        }]
    })
}

/// A SARIF run describing an evaluation that never produced a scorecard.
///
/// An error-severity scorecard finding becomes a failed assertion in
/// `scorecardToWarnings`. Evaluation therefore stops before producing a
/// report. Emit the evaluation failure as a finding so a failing job does not
/// upload an empty SARIF run.
///
/// Nix stops at the first failed assertion, so each run can report at most one
/// scorecard error. The message format, `[scorecard:<rule>] <loc>: <text>`,
/// identifies the responsible rule.
fn eval_failure_sarif(message: &str) -> serde_json::Value {
    let parsed = message
        .split_once("[scorecard:")
        .and_then(|(_, rest)| rest.split_once(']'))
        .map(|(rule, rest)| (rule.trim().to_string(), rest.trim_start().to_string()));

    let (rule_id, text) = match parsed {
        Some((rule, rest)) => (format!("scorecard/{rule}"), rest),
        None => ("kix/eval-failure".to_string(), message.to_string()),
    };

    serde_json::json!({
        "findings": [{
            "rule": rule_id,
            "severity": "error",
            "message": text,
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

    // Step 1: Nix evaluation. buildCluster runs the constructor validators,
    // the scorecard (error findings) and the cross-resource resolution
    // checks (kix/lib/eval/validate.nix) as assertions, so a failure in any
    // of them surfaces here as an eval error.
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

    // Step 2: Include scorecard findings
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
                // Evaluation succeeded with the scorecard disabled. Emit an
                // empty run because no findings were produced.
                to_sarif(&serde_json::json!({"findings": []}))
            }
        } else {
            // Evaluation failed, so there is no report to convert. Report the
            // failure itself, attributed to the scorecard rule when the
            // message names one.
            let detail = results
                .iter()
                .find(|r| r.tool == "eval" && r.result == "fail")
                .map(|r| r.details.clone())
                .unwrap_or_else(|| "cluster evaluation failed".to_string());
            to_sarif(&eval_failure_sarif(&detail))
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
    output::result(&response)?;

    if has_failure {
        std::process::exit(1);
    }

    Ok(())
}

#[cfg(test)]
mod sarif_tests {
    use super::*;

    /// `--sarif` used to emit no results when evaluation failed on an
    /// error-severity rule. The CI job failed, but its code-scanning report
    /// contained no explanation.
    #[test]
    fn a_failed_eval_becomes_a_finding_attributed_to_its_rule() {
        let msg = "[scorecard:reliability.volumeHasSource] apps/web/Deployment-web: \
                   volume 'cache' has no source";
        let sarif = to_sarif(&eval_failure_sarif(msg));
        let results = sarif["runs"][0]["results"].as_array().expect("results");

        assert_eq!(results.len(), 1, "an eval failure must produce one result");
        assert_eq!(
            results[0]["ruleId"],
            "scorecard/reliability.volumeHasSource"
        );
        assert_eq!(results[0]["level"], "error");
        assert_eq!(
            results[0]["message"]["text"],
            "apps/web/Deployment-web: volume 'cache' has no source"
        );
    }

    #[test]
    fn an_eval_failure_with_no_rule_still_reports_something() {
        let sarif = to_sarif(&eval_failure_sarif("error: attribute 'foo' missing"));
        let results = sarif["runs"][0]["results"].as_array().expect("results");

        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["ruleId"], "kix/eval-failure");
        assert_eq!(results[0]["level"], "error");
    }

    /// A successful evaluation with the scorecard disabled emits an empty run.
    #[test]
    fn no_scorecard_data_is_an_empty_run() {
        let sarif = to_sarif(&serde_json::json!({"findings": []}));
        assert!(
            sarif["runs"][0]["results"]
                .as_array()
                .expect("results")
                .is_empty()
        );
    }
}
