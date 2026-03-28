//! Rename/move detection for resources that appear only on one side.
//!
//! Uses string similarity on `"{namespace}/{name}"` plus structural
//! similarity filtering to find probable renames.

use serde_json::Value;
use strsim::normalized_levenshtein;

use crate::manifest::types::ResourceId;

use super::engine::structural_diff;
use super::{DiffConfig, Difference};

/// Minimum normalized Levenshtein similarity for a rename candidate.
const NAME_SIMILARITY_THRESHOLD: f64 = 0.6;

/// Maximum number of structural differences (excluding name/namespace fields)
/// for a rename to be considered valid.
const MAX_STRUCTURAL_DIFFS: usize = 5;

/// A detected rename/move between two resources.
#[derive(Debug, Clone)]
pub struct RenamePair {
    /// Resource ID on the kix side (source).
    pub kix_id: ResourceId,
    /// Resource ID on the cluster side (target).
    pub cluster_id: ResourceId,
    /// Name similarity score (0.0 to 1.0).
    pub similarity: f64,
    /// Structural differences between the two resources (non-name fields).
    pub diffs: Vec<Difference>,
}

/// Find probable renames between kix-only and cluster-only resources.
///
/// Only matches resources of the same kind. Uses mutual best-match:
/// A's best match must be B AND B's best match must be A.
pub fn find_renames(
    kix_only: &[(ResourceId, &Value)],
    cluster_only: &[(ResourceId, &Value)],
    config: &DiffConfig,
) -> Vec<RenamePair> {
    if kix_only.is_empty() || cluster_only.is_empty() {
        return Vec::new();
    }

    // For each kix resource, find the best cluster match (same kind only)
    let mut kix_best: Vec<Option<(usize, f64, Vec<Difference>)>> =
        Vec::with_capacity(kix_only.len());
    for (kid, kval) in kix_only {
        let mut best: Option<(usize, f64, Vec<Difference>)> = None;
        for (ci, (cid, cval)) in cluster_only.iter().enumerate() {
            if kid.kind != cid.kind {
                continue;
            }
            let sim = name_similarity(kid, cid);
            if sim < NAME_SIMILARITY_THRESHOLD {
                continue;
            }
            let diffs = non_name_diffs(kval, cval, config);
            if diffs.len() > MAX_STRUCTURAL_DIFFS {
                continue;
            }
            if best.as_ref().is_none_or(|(_, best_sim, _)| sim > *best_sim) {
                best = Some((ci, sim, diffs));
            }
        }
        kix_best.push(best);
    }

    // For each cluster resource, find the best kix match
    let mut cluster_best: Vec<Option<(usize, f64)>> = Vec::with_capacity(cluster_only.len());
    for (cid, cval) in cluster_only {
        let mut best: Option<(usize, f64)> = None;
        for (ki, (kid, kval)) in kix_only.iter().enumerate() {
            if kid.kind != cid.kind {
                continue;
            }
            let sim = name_similarity(kid, cid);
            if sim < NAME_SIMILARITY_THRESHOLD {
                continue;
            }
            let diffs = non_name_diffs(kval, cval, config);
            if diffs.len() > MAX_STRUCTURAL_DIFFS {
                continue;
            }
            if best.as_ref().is_none_or(|(_, best_sim)| sim > *best_sim) {
                best = Some((ki, sim));
            }
        }
        cluster_best.push(best);
    }

    // Mutual best-match: A's best = B AND B's best = A
    let mut renames = Vec::new();
    for (ki, kbest) in kix_best.iter().enumerate() {
        if let Some((ci, sim, diffs)) = kbest
            && let Some((best_ki, _)) = &cluster_best[*ci]
            && *best_ki == ki
        {
            renames.push(RenamePair {
                kix_id: kix_only[ki].0.clone(),
                cluster_id: cluster_only[*ci].0.clone(),
                similarity: *sim,
                diffs: diffs.clone(),
            });
        }
    }

    renames
}

/// Compute name similarity between two resources using their qualified names.
fn name_similarity(a: &ResourceId, b: &ResourceId) -> f64 {
    let a_name = format!("{}/{}", a.namespace, a.name);
    let b_name = format!("{}/{}", b.namespace, b.name);
    normalized_levenshtein(&a_name, &b_name)
}

/// Get structural diffs excluding metadata name/namespace fields.
fn non_name_diffs(a: &Value, b: &Value, config: &DiffConfig) -> Vec<Difference> {
    let mut name_config = config.clone();
    name_config
        .ignore_paths
        .insert("$.metadata.name".to_string());
    name_config
        .ignore_paths
        .insert("$.metadata.namespace".to_string());
    structural_diff(a, b, "$", &name_config)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn cfg() -> DiffConfig {
        DiffConfig::new("kix", "cluster")
    }

    fn rid(kind: &str, ns: &str, name: &str) -> ResourceId {
        ResourceId {
            kind: kind.to_string(),
            namespace: ns.to_string(),
            name: name.to_string(),
        }
    }

    #[test]
    fn detects_simple_rename() {
        let kix_val = json!({"kind": "Deployment", "metadata": {"name": "app-v2", "namespace": "default"}, "spec": {"replicas": 3}});
        let cluster_val = json!({"kind": "Deployment", "metadata": {"name": "app-v1", "namespace": "default"}, "spec": {"replicas": 3}});

        let kix_only = vec![(rid("Deployment", "default", "app-v2"), &kix_val)];
        let cluster_only = vec![(rid("Deployment", "default", "app-v1"), &cluster_val)];

        let renames = find_renames(&kix_only, &cluster_only, &cfg());
        assert_eq!(renames.len(), 1);
        assert_eq!(renames[0].kix_id.name, "app-v2");
        assert_eq!(renames[0].cluster_id.name, "app-v1");
        assert!(renames[0].similarity > 0.8);
        assert!(renames[0].diffs.is_empty()); // No structural diffs besides name
    }

    #[test]
    fn no_match_different_kind() {
        let kix_val = json!({"kind": "Deployment", "metadata": {"name": "app", "namespace": "default"}, "spec": {}});
        let cluster_val = json!({"kind": "Service", "metadata": {"name": "app", "namespace": "default"}, "spec": {}});

        let kix_only = vec![(rid("Deployment", "default", "app"), &kix_val)];
        let cluster_only = vec![(rid("Service", "default", "app"), &cluster_val)];

        let renames = find_renames(&kix_only, &cluster_only, &cfg());
        assert!(renames.is_empty());
    }
}
