//! Write a compliance audit bundle to disk.
//!
//! Produces the following tree:
//!
//! ```text
//! compliance/
//!   scorecard-results.sarif     # SARIF 2.1.0 from the scorecard
//!   sbom.json                   # CycloneDX 1.6
//!   provenance.json             # SLSA v1 in-toto Statement
//!   assessment-results.json     # OSCAL Assessment Results
//!   audit-report.md             # human-readable summary
//! ```
//!
//! The OSCAL assessment maps scorecard findings to framework controls via a
//! static mapping table in `framework_mapping`. Other
//! frameworks reuse the same mechanism.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use miette::{IntoDiagnostic, Result, miette};
use serde_json::{Value, json};

use kix::eval::store_graph::StoreGraph;

use crate::cli::{ComplianceAuditArgs, ComplianceFramework};
use crate::output;

use super::{attest, sbom, shared};
use crate::commands::CommandContext;
use kix::manifest::keys;

pub fn run(args: &ComplianceAuditArgs, ctx: &mut CommandContext) -> Result<()> {
    let out_dir = PathBuf::from(&args.out);
    if out_dir.exists() {
        if !args.force {
            return Err(miette!(
                "output directory '{}' already exists; pass --force to overwrite",
                args.out
            ));
        }
    } else {
        fs::create_dir_all(&out_dir).into_diagnostic()?;
    }

    // Build once, reuse StoreGraph + the cluster output for scorecard data.
    let graph = shared::build_and_load(ctx, &args.cluster)?;

    // The scorecard findings come from the KixEvaluator (ClusterOutput),
    // not the StoreGraph, so we run a cached eval in addition to the build.
    // The build has printed the library's warnings already.
    let cluster_output = ctx
        .evaluator()
        .ok()
        .and_then(|e| e.eval_cluster(&args.cluster).ok());
    let scorecard_findings: Vec<Value> = cluster_output
        .as_ref()
        .and_then(|o| o.scorecard_report.as_ref())
        .and_then(|r| r.get("findings").and_then(|f| f.as_array()).cloned())
        .unwrap_or_default();

    let sarif = build_sarif(&scorecard_findings);
    write_json(&out_dir.join("scorecard-results.sarif"), &sarif)?;

    let sbom = sbom::build_sbom(&graph, &ctx.global.flake);
    write_json(&out_dir.join("sbom.json"), &sbom)?;

    let provenance =
        attest::build_attestation(&graph, &ctx.global.flake, args.builder_id.as_deref(), None);
    write_json(&out_dir.join("provenance.json"), &provenance)?;

    let oscal = build_oscal(&graph, &scorecard_findings, args.framework);
    write_json(&out_dir.join("assessment-results.json"), &oscal)?;

    let md = build_markdown_summary(&graph, &scorecard_findings, args.framework);
    fs::write(out_dir.join("audit-report.md"), md).into_diagnostic()?;

    let (errors, warnings, infos) = count_findings(&scorecard_findings);
    crate::esay!();
    crate::esay!(
        "  {} audit bundle to {}",
        output::green("Wrote"),
        out_dir.display()
    );
    crate::esay!(
        "    scorecard: {} errors, {} warnings, {} info",
        errors,
        warnings,
        infos
    );
    crate::esay!("    framework: {}", framework_label(args.framework));

    Ok(())
}

fn write_json(path: &Path, value: &Value) -> Result<()> {
    let s = serde_json::to_string_pretty(value).into_diagnostic()?;
    fs::write(path, s).into_diagnostic()
}

fn count_findings(findings: &[Value]) -> (usize, usize, usize) {
    let mut errors = 0;
    let mut warnings = 0;
    let mut infos = 0;
    for f in findings {
        match f.get("severity").and_then(|s| s.as_str()) {
            Some("error") => errors += 1,
            Some("warning") => warnings += 1,
            _ => infos += 1,
        }
    }
    (errors, warnings, infos)
}

fn build_sarif(findings: &[Value]) -> Value {
    // Match the SARIF structure printed by `kix check -o sarif` so the audit
    // bundle is compatible with GitHub Code Scanning.
    let mut rules: Vec<Value> = Vec::new();
    let mut rule_indices: BTreeMap<String, usize> = BTreeMap::new();

    for f in findings {
        let rule_id = f.get("rule").and_then(|r| r.as_str()).unwrap_or("unknown");
        if !rule_indices.contains_key(rule_id) {
            let idx = rules.len();
            rule_indices.insert(rule_id.to_string(), idx);
            let level = match f.get("severity").and_then(|s| s.as_str()) {
                Some("error") => "error",
                Some("warning") => "warning",
                _ => "note",
            };
            rules.push(json!({
                "id": rule_id,
                "shortDescription": { "text": rule_id },
                "defaultConfiguration": { "level": level },
                "properties": {
                    "tags": f.get("tags").cloned().unwrap_or(json!([])),
                }
            }));
        }
    }

    let results: Vec<Value> = findings
        .iter()
        .map(|f| {
            let rule_id = f.get("rule").and_then(|r| r.as_str()).unwrap_or("unknown");
            let level = match f.get("severity").and_then(|s| s.as_str()) {
                Some("error") => "error",
                Some("warning") => "warning",
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

            let mut result = json!({
                "ruleId": rule_id,
                "ruleIndex": rule_indices.get(rule_id).copied().unwrap_or(0),
                "level": level,
                "message": { "text": message },
            });
            if !location_text.is_empty() {
                result["locations"] = json!([{
                    "logicalLocations": [{
                        "fullyQualifiedName": location_text,
                        "kind": f.get("level").and_then(|l| l.as_str()).unwrap_or("module"),
                    }]
                }]);
            }
            result
        })
        .collect();

    json!({
        "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
        "version": "2.1.0",
        "runs": [{
            "tool": {
                "driver": {
                    "name": "kix",
                    "version": kix::version::running().to_string(),
                    "informationUri": keys::WEBSITE,
                    "rules": rules,
                }
            },
            "results": results,
        }]
    })
}

fn build_oscal(graph: &StoreGraph, findings: &[Value], framework: ComplianceFramework) -> Value {
    let activation_hash = shared::activation_identity_hash(graph);
    let (errors, warnings, infos) = count_findings(findings);

    let controls = framework_controls(framework);
    let findings_json: Vec<Value> = controls
        .iter()
        .map(|c| {
            let satisfied = control_satisfied(c.id, findings);
            json!({
                "uuid": shared::new_uuid(),
                "title": format!("{}: {}", c.id.to_uppercase(), c.title),
                "description": format!(
                    "{} (cluster {} activation {}). {} scorecard rules evaluated ({} error, {} warning, {} info).",
                    c.narrative, graph.cluster_name, activation_hash, findings.len(), errors, warnings, infos
                ),
                "target": {
                    "type": "objective-id",
                    "target-id": c.id,
                    "status": {
                        "state": if satisfied { "satisfied" } else { "not-satisfied" },
                    }
                }
            })
        })
        .collect();

    let observations = vec![
        json!({
            "uuid": shared::new_uuid(),
            "description": format!("SARIF report with {} findings", findings.len()),
            "methods": ["TEST"],
            "relevant-evidence": [{
                "href": "./scorecard-results.sarif",
                "description": "Full scorecard findings in SARIF 2.1.0 format",
            }]
        }),
        json!({
            "uuid": shared::new_uuid(),
            "description": format!("CycloneDX SBOM with {} packages", graph.packages.len()),
            "methods": ["EXAMINE"],
            "relevant-evidence": [{
                "href": "./sbom.json",
                "description": "Software Bill of Materials (CycloneDX 1.6)",
            }]
        }),
        json!({
            "uuid": shared::new_uuid(),
            "description": "SLSA v1 provenance attestation",
            "methods": ["EXAMINE"],
            "relevant-evidence": [{
                "href": "./provenance.json",
                "description": "in-toto Statement with SLSA v1 predicate",
            }]
        }),
    ];

    json!({
        "assessment-results": {
            "uuid": shared::new_uuid(),
            "metadata": {
                "title": format!(
                    "kix compliance assessment — cluster {} ({} framework)",
                    graph.cluster_name,
                    framework_label(framework),
                ),
                "last-modified": shared::now_rfc3339(),
                "version": kix::version::running().to_string(),
                "oscal-version": "1.1.2",
            },
            "import-ap": { "href": "./component-definition.json" },
            "results": [{
                "uuid": shared::new_uuid(),
                "title": "Build-time assessment",
                "description": format!(
                    "kix evaluated {} scorecard rules at build time for activation {}",
                    findings.len(), activation_hash
                ),
                "start": shared::now_rfc3339(),
                "end": shared::now_rfc3339(),
                "reviewed-controls": {
                    "control-selections": [{
                        "include-controls": controls.iter()
                            .map(|c| json!({ "control-id": c.id }))
                            .collect::<Vec<_>>(),
                    }]
                },
                "findings": findings_json,
                "observations": observations,
            }]
        }
    })
}

/// One control entry in a framework mapping table.
struct Control {
    id: &'static str,
    title: &'static str,
    narrative: &'static str,
    /// Rule name prefixes (or exact rule IDs) whose error-level findings mark
    /// the control as not-satisfied. When empty, the control is satisfied by
    /// the generated bundle artifacts (such as the SBOM) alone.
    required_rules: &'static [&'static str],
}

fn control_satisfied(id: &str, findings: &[Value]) -> bool {
    let controls = framework_controls(ComplianceFramework::Soc2);
    let all = framework_controls(ComplianceFramework::Iso27001);
    let dora = framework_controls(ComplianceFramework::Dora);
    let nis2 = framework_controls(ComplianceFramework::Nis2);
    for set in [controls, all, dora, nis2] {
        if let Some(c) = set.iter().find(|c| c.id == id) {
            if c.required_rules.is_empty() {
                return true;
            }
            let any_error = findings.iter().any(|f| {
                let sev = f.get("severity").and_then(|s| s.as_str()).unwrap_or("");
                if sev != "error" {
                    return false;
                }
                let rule = f.get("rule").and_then(|r| r.as_str()).unwrap_or("");
                c.required_rules
                    .iter()
                    .any(|prefix| rule.starts_with(prefix))
            });
            return !any_error;
        }
    }
    true
}

fn framework_label(f: ComplianceFramework) -> &'static str {
    match f {
        ComplianceFramework::Soc2 => "SOC 2",
        ComplianceFramework::Iso27001 => "ISO 27001:2022",
        ComplianceFramework::Dora => "DORA (EU Digital Operational Resilience Act)",
        ComplianceFramework::Nis2 => "NIS2 (EU Network and Information Security Directive)",
    }
}

/// Return the static control-to-rule mapping table for `f`.
fn framework_controls(f: ComplianceFramework) -> &'static [Control] {
    match f {
        ComplianceFramework::Soc2 => SOC2,
        ComplianceFramework::Iso27001 => ISO27001,
        ComplianceFramework::Dora => DORA,
        ComplianceFramework::Nis2 => NIS2,
    }
}

static SOC2: &[Control] = &[
    Control {
        id: "cc6.1",
        title: "Change Management",
        narrative: "Every deployment is a content-addressed kix activation traceable to a specific build. SLSA provenance proves the builder identity; scorecard results demonstrate policy checks passed.",
        required_rules: &["security."],
    },
    Control {
        id: "cc6.2",
        title: "System Component Inventory",
        narrative: "CycloneDX SBOM enumerates every package, container image, Helm chart, and Nix flake input with versions and hashes.",
        required_rules: &[],
    },
    Control {
        id: "cc6.8",
        title: "Vulnerability Management",
        narrative: "Scorecard rules enforce image hygiene (pinned tags, no latest, no privileged). SBOM feeds downstream CVE scanning.",
        required_rules: &["security.image", "security.privileged"],
    },
    Control {
        id: "cc7.1",
        title: "Detection of Unauthorized Changes",
        narrative: "`kix status --check drift` compares each live object with what Kix applied, and names the fields that changed and the tool that changed them.",
        required_rules: &[],
    },
    Control {
        id: "cc7.2",
        title: "Monitoring System Components",
        narrative: "Scorecard `observability.*` rules ensure every workload has a ServiceMonitor and logging pipeline.",
        required_rules: &["observability."],
    },
    Control {
        id: "cc8.1",
        title: "Authorization of Changes",
        narrative: "Git PR approval + SLSA provenance record the authorized build path. Error-level scorecard rules block unauthorized patterns at build time.",
        required_rules: &["security."],
    },
];

static ISO27001: &[Control] = &[
    Control {
        id: "a.8.9",
        title: "Configuration Management",
        narrative: "Cluster definitions are the baseline; activation hashes prove reproducibility.",
        required_rules: &[],
    },
    Control {
        id: "a.8.25",
        title: "Secure Development Lifecycle",
        narrative: "Scorecard rules enforce security policy at build time — prevention by construction, not detection.",
        required_rules: &["security."],
    },
    Control {
        id: "a.8.8",
        title: "Management of Technical Vulnerabilities",
        narrative: "SBOM enables vulnerability scanning; scorecard rules guard image hygiene.",
        required_rules: &["security.image"],
    },
    Control {
        id: "a.8.22",
        title: "Segregation of Networks",
        narrative: "NetworkPolicies are auto-derived from the DI graph (kix/lib/plugins/netpol).",
        required_rules: &["security.network"],
    },
    Control {
        id: "a.5.9",
        title: "Inventory of Information Assets",
        narrative: "CycloneDX SBOM is a complete, automatically-maintained asset inventory.",
        required_rules: &[],
    },
    Control {
        id: "a.8.32",
        title: "Change Management",
        narrative: "Same evidence as SOC 2 CC6.1 — activation provenance + policy gating.",
        required_rules: &["security."],
    },
];

static DORA: &[Control] = &[
    Control {
        id: "art.9",
        title: "Protection and Prevention",
        narrative: "Scorecard rules enforce security standards at build time; network policies derived from the DI graph.",
        required_rules: &["security."],
    },
    Control {
        id: "art.9.4.c",
        title: "Detection of Anomalous Activities",
        narrative: "`kix status --check drift` detects changes to what Kix applied; operator reconcile heals drift automatically.",
        required_rules: &[],
    },
    Control {
        id: "art.10",
        title: "Detection",
        narrative: "Topology-aware monitoring auto-generates alerts from the dependency graph.",
        required_rules: &["observability."],
    },
    Control {
        id: "art.11",
        title: "Response and Recovery",
        narrative: "`kix rollback` provides instant recovery to any previous activation; deterministic builds mean historical state is reproducible.",
        required_rules: &[],
    },
    Control {
        id: "art.12",
        title: "Backup Policies",
        narrative: "Scorecard rule `reliability.hasBackup` checks stateful packages.",
        required_rules: &["reliability.hasBackup"],
    },
    Control {
        id: "art.28",
        title: "ICT Third-Party Risk Register",
        narrative: "CycloneDX SBOM lists all third-party components with provenance.",
        required_rules: &[],
    },
];

static NIS2: &[Control] = &[
    Control {
        id: "art.21.2.a",
        title: "Risk Management Measures",
        narrative: "Scorecard rules are the risk management measures; SARIF report is the evidence.",
        required_rules: &["security."],
    },
    Control {
        id: "art.21.2.d",
        title: "Supply Chain Security",
        narrative: "CycloneDX SBOM + SLSA provenance + Nix locked inputs.",
        required_rules: &[],
    },
    Control {
        id: "art.21.2.e",
        title: "Security in Acquisition, Development, Maintenance",
        narrative: "Build-time policy enforcement via scorecard.",
        required_rules: &["security."],
    },
    Control {
        id: "art.21.2.h",
        title: "Cryptography and Encryption",
        narrative: "Content-addressed activation; Ed25519 signing designed in doc 54.",
        required_rules: &[],
    },
    Control {
        id: "art.21.2.c",
        title: "Business Continuity / Disaster Recovery",
        narrative: "`kix rollback` + deterministic builds + backup scorecard rules.",
        required_rules: &["reliability.hasBackup"],
    },
];

fn build_markdown_summary(
    graph: &StoreGraph,
    findings: &[Value],
    framework: ComplianceFramework,
) -> String {
    let (errors, warnings, infos) = count_findings(findings);
    let activation_hash = shared::activation_identity_hash(graph);
    let controls = framework_controls(framework);

    let mut s = String::new();
    s.push_str(&format!(
        "# kix compliance audit — cluster `{}`\n\n",
        graph.cluster_name
    ));
    s.push_str(&format!("**Framework:** {}\n", framework_label(framework)));
    s.push_str(&format!("**Activation:** `{activation_hash}`\n"));
    s.push_str(&format!("**Generated:** {}\n\n", shared::now_rfc3339()));

    s.push_str("## Summary\n\n");
    s.push_str(&format!("- **Packages:** {}\n", graph.packages.len()));
    s.push_str(&format!("- **Resources:** {}\n", graph.resources.len()));
    s.push_str(&format!(
        "- **Scorecard findings:** {} errors, {} warnings, {} info\n\n",
        errors, warnings, infos
    ));

    s.push_str("## Evidence artifacts\n\n");
    s.push_str("| File | Format | Purpose |\n|---|---|---|\n");
    s.push_str("| `scorecard-results.sarif` | SARIF 2.1.0 | Static analysis findings (GitHub Code Scanning compatible) |\n");
    s.push_str("| `sbom.json` | CycloneDX 1.6 | Software Bill of Materials |\n");
    s.push_str("| `provenance.json` | in-toto / SLSA v1 | Build provenance attestation |\n");
    s.push_str("| `assessment-results.json` | OSCAL 1.1.2 | Control-to-evidence mapping |\n\n");

    s.push_str(&format!(
        "## {} control coverage\n\n",
        framework_label(framework)
    ));
    s.push_str("| Control | Title | Status |\n|---|---|---|\n");
    for c in controls {
        let satisfied = control_satisfied(c.id, findings);
        let status = if satisfied {
            "satisfied"
        } else {
            "not-satisfied"
        };
        s.push_str(&format!(
            "| `{}` | {} | {} |\n",
            c.id.to_uppercase(),
            c.title,
            status
        ));
    }
    s.push('\n');

    if errors > 0 {
        s.push_str("## Unresolved error findings\n\n");
        for f in findings
            .iter()
            .filter(|f| f.get("severity").and_then(|s| s.as_str()) == Some("error"))
        {
            let rule = f.get("rule").and_then(|r| r.as_str()).unwrap_or("?");
            let msg = f.get("message").and_then(|m| m.as_str()).unwrap_or("");
            s.push_str(&format!("- **{rule}** — {msg}\n"));
        }
        s.push('\n');
    }

    s.push_str("---\n\n");
    s.push_str(
        "_Generated by `kix compliance audit`. See `v2_discussions/61_compliance_exports.md`._\n",
    );
    s
}
