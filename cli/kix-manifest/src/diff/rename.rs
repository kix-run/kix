//! Rename/move detection for resources that appear only on one side.
//!
//! Uses string similarity on `"{namespace}/{name}"` plus structural
//! similarity filtering to find probable renames.

use serde_json::Value;
use strsim::normalized_levenshtein;

use crate::types::ResourceId;

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

    #[test]
    fn no_match_too_different_names() {
        let kix_val =
            json!({"kind": "Deployment", "metadata": {"name": "alpha", "namespace": "default"}});
        let cluster_val = json!({"kind": "Deployment", "metadata": {"name": "zzzzz-totally-different", "namespace": "default"}});

        let kix_only = vec![(rid("Deployment", "default", "alpha"), &kix_val)];
        let cluster_only = vec![(
            rid("Deployment", "default", "zzzzz-totally-different"),
            &cluster_val,
        )];

        let renames = find_renames(&kix_only, &cluster_only, &cfg());
        assert!(renames.is_empty());
    }

    #[test]
    fn no_match_too_many_structural_diffs() {
        let kix_val = json!({
            "kind": "Deployment",
            "metadata": {"name": "app-v2", "namespace": "default"},
            "spec": {"replicas": 3, "image": "foo", "port": 80, "env": "a", "volume": "/x", "extra": "y"}
        });
        let cluster_val = json!({
            "kind": "Deployment",
            "metadata": {"name": "app-v1", "namespace": "default"},
            "spec": {"replicas": 1, "image": "bar", "port": 443, "env": "b", "volume": "/z", "extra": "n"}
        });

        let kix_only = vec![(rid("Deployment", "default", "app-v2"), &kix_val)];
        let cluster_only = vec![(rid("Deployment", "default", "app-v1"), &cluster_val)];

        let renames = find_renames(&kix_only, &cluster_only, &cfg());
        assert!(renames.is_empty()); // 6 diffs > threshold of 5
    }

    #[test]
    fn mutual_best_match() {
        // Three resources: kix has app-v2, cluster has app-v1 and app-v0
        // app-v2 is more similar to app-v1, so it should match app-v1
        let kix_val = json!({"kind": "Deployment", "metadata": {"name": "app-v2", "namespace": "ns"}, "spec": {"replicas": 3}});
        let cluster_val1 = json!({"kind": "Deployment", "metadata": {"name": "app-v1", "namespace": "ns"}, "spec": {"replicas": 3}});
        let cluster_val0 = json!({"kind": "Deployment", "metadata": {"name": "app-v0", "namespace": "ns"}, "spec": {"replicas": 3}});

        let kix_only = vec![(rid("Deployment", "ns", "app-v2"), &kix_val)];
        let cluster_only = vec![
            (rid("Deployment", "ns", "app-v1"), &cluster_val1),
            (rid("Deployment", "ns", "app-v0"), &cluster_val0),
        ];

        let renames = find_renames(&kix_only, &cluster_only, &cfg());
        assert_eq!(renames.len(), 1);
        assert_eq!(renames[0].cluster_id.name, "app-v1");
    }

    #[test]
    fn mutual_best_match_prevents_wrong_pair() {
        // kix: A, B; cluster: A', B'
        // A is best match for B' and B is best match for A' but
        // A' best match is A and B' best match is B — only mutual matches count
        let a = json!({"kind": "Service", "metadata": {"name": "svc-alpha", "namespace": "ns"}, "spec": {"port": 80}});
        let b = json!({"kind": "Service", "metadata": {"name": "svc-beta", "namespace": "ns"}, "spec": {"port": 443}});
        let a_prime = json!({"kind": "Service", "metadata": {"name": "svc-alpha-v2", "namespace": "ns"}, "spec": {"port": 80}});
        let b_prime = json!({"kind": "Service", "metadata": {"name": "svc-beta-v2", "namespace": "ns"}, "spec": {"port": 443}});

        let kix_only = vec![
            (rid("Service", "ns", "svc-alpha"), &a),
            (rid("Service", "ns", "svc-beta"), &b),
        ];
        let cluster_only = vec![
            (rid("Service", "ns", "svc-alpha-v2"), &a_prime),
            (rid("Service", "ns", "svc-beta-v2"), &b_prime),
        ];

        let renames = find_renames(&kix_only, &cluster_only, &cfg());
        assert_eq!(renames.len(), 2);
        // alpha should match alpha-v2, beta should match beta-v2
        let alpha_rename = renames
            .iter()
            .find(|r| r.kix_id.name == "svc-alpha")
            .unwrap();
        assert_eq!(alpha_rename.cluster_id.name, "svc-alpha-v2");
        let beta_rename = renames
            .iter()
            .find(|r| r.kix_id.name == "svc-beta")
            .unwrap();
        assert_eq!(beta_rename.cluster_id.name, "svc-beta-v2");
    }

    #[test]
    fn namespace_move_detected() {
        // Use similar namespace names so similarity >= 0.6
        let kix_val = json!({"kind": "ConfigMap", "metadata": {"name": "config", "namespace": "app-prod"}, "data": {"key": "val"}});
        let cluster_val = json!({"kind": "ConfigMap", "metadata": {"name": "config", "namespace": "app-dev"}, "data": {"key": "val"}});

        let kix_only = vec![(rid("ConfigMap", "app-prod", "config"), &kix_val)];
        let cluster_only = vec![(rid("ConfigMap", "app-dev", "config"), &cluster_val)];

        let renames = find_renames(&kix_only, &cluster_only, &cfg());
        assert_eq!(renames.len(), 1);
        assert_eq!(renames[0].kix_id.namespace, "app-prod");
        assert_eq!(renames[0].cluster_id.namespace, "app-dev");
    }

    #[test]
    fn empty_inputs() {
        let val = json!({"kind": "Service"});
        let kix_only = vec![(rid("Service", "ns", "svc"), &val)];
        assert!(find_renames(&kix_only, &[], &cfg()).is_empty());
        assert!(find_renames(&[], &kix_only, &cfg()).is_empty());
        let empty_kix: Vec<(ResourceId, &Value)> = vec![];
        let empty_cluster: Vec<(ResourceId, &Value)> = vec![];
        assert!(find_renames(&empty_kix, &empty_cluster, &cfg()).is_empty());
    }

    #[test]
    fn rename_with_minor_structural_diff() {
        let kix_val = json!({
            "kind": "Deployment",
            "metadata": {"name": "web-v2", "namespace": "default"},
            "spec": {"replicas": 3, "image": "nginx:1.25"}
        });
        let cluster_val = json!({
            "kind": "Deployment",
            "metadata": {"name": "web-v1", "namespace": "default"},
            "spec": {"replicas": 3, "image": "nginx:1.24"}
        });

        let kix_only = vec![(rid("Deployment", "default", "web-v2"), &kix_val)];
        let cluster_only = vec![(rid("Deployment", "default", "web-v1"), &cluster_val)];

        let renames = find_renames(&kix_only, &cluster_only, &cfg());
        assert_eq!(renames.len(), 1);
        assert_eq!(renames[0].diffs.len(), 1); // image diff
    }
}
