//! Preflight validation tools for K8s manifests.
//!
//! Trait-based extensible preflight system. Each tool runs against a directory
//! of rendered YAML manifests and produces structured results.

use std::path::Path;

use serde::{Deserialize, Serialize};

/// Severity level for a preflight finding.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Error,
    Warning,
    Info,
}

/// A single finding from a preflight tool.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Finding {
    pub severity: Severity,
    /// The resource this finding relates to (e.g. "Deployment/my-app@default").
    pub resource: Option<String>,
    pub message: String,
}

/// Result from running a preflight tool.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreflightResult {
    pub passed: bool,
    pub tool: String,
    pub details: String,
    pub findings: Vec<Finding>,
}

/// A preflight validation tool that checks manifests for issues.
pub trait PreflightTool {
    /// Tool name shown in output (e.g. "kubeconform").
    fn name(&self) -> &str;

    /// Run the tool against a directory of YAML manifests.
    fn run(&self, manifest_dir: &Path) -> PreflightResult;
}

/// Run all preflight tools against a manifest directory.
pub fn run_preflight(manifest_dir: &Path, tools: &[&dyn PreflightTool]) -> Vec<PreflightResult> {
    tools.iter().map(|tool| tool.run(manifest_dir)).collect()
}

// --- Stub tools ---

/// Kubeconform schema validation (placeholder).
pub struct KubeconformTool;

impl PreflightTool for KubeconformTool {
    fn name(&self) -> &str {
        "kubeconform"
    }

    fn run(&self, _manifest_dir: &Path) -> PreflightResult {
        PreflightResult {
            passed: true,
            tool: self.name().to_string(),
            details: "skipped (not installed)".into(),
            findings: vec![],
        }
    }
}

/// Pluto deprecated API detection (placeholder).
pub struct PlutoTool;

impl PreflightTool for PlutoTool {
    fn name(&self) -> &str {
        "pluto"
    }

    fn run(&self, _manifest_dir: &Path) -> PreflightResult {
        PreflightResult {
            passed: true,
            tool: self.name().to_string(),
            details: "skipped (not installed)".into(),
            findings: vec![],
        }
    }
}

/// Kyverno policy validation (placeholder).
pub struct KyvernoTool;

impl PreflightTool for KyvernoTool {
    fn name(&self) -> &str {
        "kyverno"
    }

    fn run(&self, _manifest_dir: &Path) -> PreflightResult {
        PreflightResult {
            passed: true,
            tool: self.name().to_string(),
            details: "skipped (not installed)".into(),
            findings: vec![],
        }
    }
}

/// Returns the default set of preflight tools.
pub fn default_tools() -> Vec<Box<dyn PreflightTool>> {
    vec![
        Box::new(KubeconformTool),
        Box::new(PlutoTool),
        Box::new(KyvernoTool),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn stub_tools_return_skipped() {
        let dir = PathBuf::from("/tmp/nonexistent");
        let tools: Vec<Box<dyn PreflightTool>> = default_tools();
        let tool_refs: Vec<&dyn PreflightTool> = tools.iter().map(|t| t.as_ref()).collect();
        let results = run_preflight(&dir, &tool_refs);

        assert_eq!(results.len(), 3);
        for result in &results {
            assert!(result.passed);
            assert!(result.details.contains("skipped"));
            assert!(result.findings.is_empty());
        }
    }

    #[test]
    fn tool_names() {
        assert_eq!(KubeconformTool.name(), "kubeconform");
        assert_eq!(PlutoTool.name(), "pluto");
        assert_eq!(KyvernoTool.name(), "kyverno");
    }

    #[test]
    fn severity_serialization() {
        let json = serde_json::to_string(&Severity::Error).unwrap();
        assert_eq!(json, "\"error\"");
        let json = serde_json::to_string(&Severity::Warning).unwrap();
        assert_eq!(json, "\"warning\"");
    }

    #[test]
    fn preflight_result_serialization() {
        let result = PreflightResult {
            passed: false,
            tool: "test".into(),
            details: "found issues".into(),
            findings: vec![Finding {
                severity: Severity::Error,
                resource: Some("Deployment/app@default".into()),
                message: "invalid schema".into(),
            }],
        };
        let json = serde_json::to_string_pretty(&result).unwrap();
        assert!(json.contains("\"tool\": \"test\""));
        assert!(json.contains("\"severity\": \"error\""));
        assert!(json.contains("invalid schema"));
    }

    struct FailingTool;
    impl PreflightTool for FailingTool {
        fn name(&self) -> &str {
            "failing"
        }
        fn run(&self, _manifest_dir: &Path) -> PreflightResult {
            PreflightResult {
                passed: false,
                tool: self.name().to_string(),
                details: "2 errors found".into(),
                findings: vec![
                    Finding {
                        severity: Severity::Error,
                        resource: Some("Deployment/bad@ns".into()),
                        message: "missing required field".into(),
                    },
                    Finding {
                        severity: Severity::Warning,
                        resource: None,
                        message: "deprecated API version".into(),
                    },
                ],
            }
        }
    }

    #[test]
    fn custom_tool_in_pipeline() {
        let dir = PathBuf::from("/tmp/nonexistent");
        let failing = FailingTool;
        let kubeconform = KubeconformTool;
        let tools: Vec<&dyn PreflightTool> = vec![&kubeconform, &failing];
        let results = run_preflight(&dir, &tools);

        assert_eq!(results.len(), 2);
        assert!(results[0].passed);
        assert!(!results[1].passed);
        assert_eq!(results[1].findings.len(), 2);
        assert_eq!(results[1].findings[0].severity, Severity::Error);
        assert_eq!(results[1].findings[1].severity, Severity::Warning);
    }
}
