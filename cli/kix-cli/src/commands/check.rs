use miette::Result;

use crate::cli::CheckArgs;
use crate::exit::Exit;
use crate::output::{self, CommandResponse};

use super::CommandContext;
use kix::manifest::keys;

#[derive(serde::Serialize)]
struct CheckResult {
    tool: String,
    result: String,
    details: String,
    /// The scorecard's findings, on the scorecard row only.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    findings: Vec<serde_json::Value>,
}

struct CheckResponse {
    results: Vec<CheckResult>,
    /// Whether to list `info` findings too.
    verbose: bool,
}

/// The longest one-line detail kept in the table. Longer ones would stretch
/// every row of the table past the width of a terminal.
const MAX_CELL_CHARS: usize = 80;

impl CommandResponse for CheckResponse {
    fn format_text(&self) -> String {
        let mut table = comfy_table::Table::new();
        table.load_preset(comfy_table::presets::NOTHING);
        table.set_header(["TOOL", "RESULT", "DETAILS"]);
        // A message of several lines, or one too long for a terminal line,
        // does not fit a table cell, so it goes under the table.
        let mut below = Vec::new();
        for r in &self.results {
            if r.details.contains('\n') || r.details.chars().count() > MAX_CELL_CHARS {
                table.add_row([r.tool.as_str(), r.result.as_str(), "see below"]);
                below.push(r.details.trim_end().to_string());
            } else {
                table.add_row([&r.tool, &r.result, &r.details]);
            }
        }
        let mut text = table.to_string();
        for detail in below {
            text.push_str("\n\n");
            text.push_str(&detail);
        }
        for r in &self.results {
            let listed = list_findings(&r.findings, self.verbose);
            if !listed.is_empty() {
                text.push_str("\n\n");
                text.push_str(&listed);
            }
        }
        text
    }

    fn as_json(&self) -> serde_json::Value {
        serde_json::to_value(&self.results).unwrap_or_default()
    }
}

/// Return the scorecard findings as text, grouped by rule, errors first.
/// `info` findings are listed only when `verbose`.
fn list_findings(findings: &[serde_json::Value], verbose: bool) -> String {
    let field =
        |f: &serde_json::Value, k: &str| f.get(k).and_then(|v| v.as_str()).map(str::to_string);
    let mut groups: std::collections::BTreeMap<(u8, String), Vec<String>> = Default::default();
    let mut hidden = 0;
    for f in findings {
        let severity = field(f, "severity").unwrap_or_else(|| "warning".into());
        let rank = match severity.as_str() {
            "error" => 0,
            "warning" => 1,
            _ => 2,
        };
        if rank == 2 && !verbose {
            hidden += 1;
            continue;
        }
        let place = ["namespace", "instance", "resource"]
            .iter()
            .filter_map(|k| field(f, k))
            .collect::<Vec<_>>()
            .join("/");
        let message = field(f, "message").unwrap_or_default();
        let line = if place.is_empty() {
            message
        } else {
            format!("{place}: {message}")
        };
        let rule = field(f, "rule").unwrap_or_else(|| "unknown".into());
        groups
            .entry((rank, format!("{rule} ({severity})")))
            .or_default()
            .push(line);
    }
    let mut out: Vec<String> = groups
        .into_iter()
        .map(|((_, rule), lines)| {
            let mut block = format!("{rule}, {}:", lines.len());
            for line in lines {
                block.push_str("\n  ");
                block.push_str(&line);
            }
            block
        })
        .collect();
    if hidden > 0 {
        out.push(format!(
            "{hidden} info finding(s) not listed; run with -v to list them."
        ));
    }
    out.join("\n\n")
}

/// Convert scorecard findings to SARIF 2.1.0 JSON.
fn to_sarif(scorecard_report: &serde_json::Value) -> serde_json::Value {
    let findings = scorecard_report
        .get("findings")
        .and_then(|f| f.as_array())
        .cloned()
        .unwrap_or_default();

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

/// Build a synthetic scorecard report for an evaluation that failed before
/// producing a scorecard.
///
/// An error-severity scorecard finding becomes a failed assertion in
/// `scorecardToWarnings`, which stops evaluation before a report is produced.
/// Emit the evaluation failure as a finding so a failing job does not upload an
/// empty SARIF run.
///
/// Nix stops at the first failed assertion, so each run can report at most one
/// scorecard error. The message format `[scorecard:<rule>] <loc>: <text>`
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

pub fn run(args: &CheckArgs, ctx: &mut CommandContext) -> Result<Exit> {
    let mut results: Vec<CheckResult> = Vec::new();

    let spinner = output::spinner(format!("Checking cluster '{}'...", args.cluster));

    // `buildCluster` runs constructor validators, error-severity scorecard
    // rules, and cross-resource resolution checks (`kix/lib/eval/validate.nix`)
    // as assertions, so a failure in any of them surfaces here as an eval error.
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
                findings: Vec::new(),
            });
            Some(output)
        }
        Err(kix::eval::error::KixEvalError::ClusterNotFound { name }) => {
            return Err(miette::miette!("{}", ctx.cluster_not_found(name)));
        }
        Err(e) => {
            results.push(CheckResult {
                tool: "eval".into(),
                result: "fail".into(),
                details: e.to_string(),
                findings: Vec::new(),
            });
            None
        }
    };

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
                    findings: findings.clone(),
                });
            }
        } else {
            results.push(CheckResult {
                tool: "scorecard".into(),
                result: "skip".into(),
                details: "scorecard not enabled in cluster definition".into(),
                findings: Vec::new(),
            });
        }
    }

    let has_failure = results.iter().any(|r| r.result == "fail");

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
            // Evaluation failed before producing a report. Emit the failure
            // itself, attributed to the scorecard rule when the message names one.
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

        return Ok(Exit::failure_if(has_failure));
    }

    let response = CheckResponse {
        results,
        verbose: ctx.global.verbose > 0,
    };
    output::result(&response)?;
    Ok(Exit::failure_if(has_failure))
}

#[cfg(test)]
mod sarif_tests {
    use super::*;

    /// Verify that an evaluation failure from an error-severity rule produces a
    /// SARIF finding attributed to that rule.
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

    /// Verify that a successful evaluation with the scorecard disabled emits an
    /// empty SARIF run.
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
