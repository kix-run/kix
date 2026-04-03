//! Pre-deploy import validation.
//!
//! Scans manifest set for import markers (PackageInstance CRs with
//! `kix.dev/mode: import`) and verifies the imported resources exist
//! in the live cluster before deployment proceeds.

use kube::api::{Api, DynamicObject};
use kube::client::Client;
use kube::discovery::{ApiResource, Scope};

/// An import found in the manifest set.
#[derive(Debug, Clone)]
pub struct ImportMarker {
    /// Instance name (from the marker CR)
    pub instance_name: String,
    /// Namespace the import lives in
    pub namespace: String,
    /// Imported resource name (from kix.dev/import-name)
    pub import_name: Option<String>,
    /// Imported resource FQDN (from kix.dev/import-fqdn)
    pub import_fqdn: Option<String>,
    /// K8s resource kind hint (from kix.dev/import-kind)
    pub import_kind: Option<String>,
    /// K8s apiVersion hint (from kix.dev/import-apiversion)
    pub import_api_version: Option<String>,
}

/// Result of validating a single import.
#[derive(Debug)]
pub enum ImportCheckResult {
    /// Resource found in the cluster.
    Verified,
    /// Resource not found — kind+name were checked.
    NotFound { detail: String },
    /// No kind hint — only namespace was verifiable.
    Unverifiable,
}

/// Extract import markers from a set of manifests.
pub fn collect_import_markers(manifests: &[serde_json::Value]) -> Vec<ImportMarker> {
    manifests
        .iter()
        .filter(|m| {
            m.get("kind")
                .and_then(|v| v.as_str())
                .is_some_and(|k| k == "PackageInstance")
                && get_annotation(m, "kix.dev/mode").as_deref() == Some("import")
        })
        .map(|m| {
            let instance_name = m
                .pointer("/metadata/name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let namespace = m
                .pointer("/metadata/namespace")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            ImportMarker {
                instance_name,
                namespace,
                import_name: get_annotation(m, "kix.dev/import-name"),
                import_fqdn: get_annotation(m, "kix.dev/import-fqdn"),
                import_kind: get_annotation(m, "kix.dev/import-kind"),
                import_api_version: get_annotation(m, "kix.dev/import-apiversion"),
            }
        })
        .collect()
}

/// Validate import markers against the live cluster.
///
/// For imports with kind + apiVersion hints, performs a targeted GET to verify
/// the resource exists. For imports without hints, reports them as unverifiable.
///
/// Returns a vec of (marker, result) pairs.
pub async fn validate_imports(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    markers: &[ImportMarker],
) -> Vec<(ImportMarker, ImportCheckResult)> {
    let mut results = Vec::new();

    for marker in markers {
        let result = validate_one(client, discovery, marker).await;
        results.push((marker.clone(), result));
    }

    results
}

async fn validate_one(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    marker: &ImportMarker,
) -> ImportCheckResult {
    let (Some(kind), Some(api_version)) = (&marker.import_kind, &marker.import_api_version) else {
        return ImportCheckResult::Unverifiable;
    };

    let import_name = match &marker.import_name {
        Some(n) => n,
        None => return ImportCheckResult::Unverifiable,
    };

    // Find the API resource in discovery that matches kind + apiVersion
    let ar = discovery
        .iter()
        .find(|(ar, _)| ar.kind.eq_ignore_ascii_case(kind) && matches_api_version(ar, api_version));

    let Some((ar, scope)) = ar else {
        return ImportCheckResult::NotFound {
            detail: format!(
                "{}/{} '{}' — API kind not registered on cluster",
                api_version, kind, import_name
            ),
        };
    };

    // Perform targeted GET
    let api: Api<DynamicObject> = match scope {
        Scope::Namespaced => {
            let ns = if marker.namespace.is_empty() {
                "default"
            } else {
                &marker.namespace
            };
            Api::namespaced_with(client.clone(), ns, ar)
        }
        Scope::Cluster => Api::all_with(client.clone(), ar),
    };

    match api.get_opt(import_name).await {
        Ok(Some(_)) => ImportCheckResult::Verified,
        Ok(None) => ImportCheckResult::NotFound {
            detail: format!(
                "{} '{}' in namespace '{}'",
                kind, import_name, marker.namespace
            ),
        },
        Err(e) => {
            // API errors (RBAC, etc.) — treat as unverifiable rather than failing
            tracing::warn!(
                import = marker.instance_name,
                error = %e,
                "import validation API error, treating as unverifiable"
            );
            ImportCheckResult::Unverifiable
        }
    }
}

/// Check if an ApiResource matches a given apiVersion string like "v1" or "apps/v1".
fn matches_api_version(ar: &ApiResource, api_version: &str) -> bool {
    if ar.group.is_empty() {
        // Core group: apiVersion is just the version (e.g. "v1")
        ar.version == api_version
    } else {
        // Named group: apiVersion is "group/version" (e.g. "apps/v1")
        let full = format!("{}/{}", ar.group, ar.version);
        full == api_version
    }
}

fn get_annotation(manifest: &serde_json::Value, key: &str) -> Option<String> {
    manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(key))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

/// Format validation results for display.
pub fn format_validation_summary(results: &[(ImportMarker, ImportCheckResult)]) -> Vec<String> {
    let mut lines = Vec::new();

    let verified = results
        .iter()
        .filter(|(_, r)| matches!(r, ImportCheckResult::Verified))
        .count();
    let not_found: Vec<_> = results
        .iter()
        .filter(|(_, r)| matches!(r, ImportCheckResult::NotFound { .. }))
        .collect();
    let unverifiable = results
        .iter()
        .filter(|(_, r)| matches!(r, ImportCheckResult::Unverifiable))
        .count();

    if verified > 0 {
        lines.push(format!("  {} {} imports verified", "✓", verified));
    }
    if unverifiable > 0 {
        lines.push(format!(
            "  {} {} imports unverifiable (no kind hint)",
            "?", unverifiable
        ));
    }
    for (marker, result) in &not_found {
        if let ImportCheckResult::NotFound { detail } = result {
            lines.push(format!(
                "  {} import '{}': {} not found",
                "✗", marker.instance_name, detail
            ));
        }
    }

    lines
}
