//! Shared helpers for `kix logs` / `kix pf`: build the cluster, resolve a
//! package-instance name to its primary workload (Deployment / StatefulSet /
//! DaemonSet), and extract the label selector for downstream `kubectl` calls.
//!
//! Both commands deliberately shell out to `kubectl logs` / `kubectl
//! port-forward`. The point is "one tool" in the demo, not re-implementing
//! log streaming or port proxying. Per
//! `v2_discussions/84_m0_m1_implementation_plan.md` §4.

use std::path::{Path, PathBuf};

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::eval::build_cluster_activation_with_status;
use kix::eval::store_graph::{PackageNode, StoreGraph};
use kix::manifest::stamp::stamp_annotations;

/// A workload resolved from a package instance. Contains everything the
/// downstream `kubectl` shell-out needs.
pub struct WorkloadTarget {
    /// `Deployment`, `StatefulSet`, or `DaemonSet`.
    pub kind: String,
    pub namespace: String,
    pub name: String,
    /// Label selector in `kubectl -l` syntax, e.g. `app=foo,instance=bar`.
    /// Built from `spec.selector.matchLabels` on the workload.
    pub selector: String,
}

impl WorkloadTarget {
    /// `kind/name` form used by `kubectl port-forward deployment/foo`.
    pub fn kubectl_ref(&self) -> String {
        format!("{}/{}", self.kind.to_lowercase(), self.name)
    }
}

/// Kinds we treat as a package's "primary workload" when it has no explicit
/// pointer. Ordered by preference — e.g. if a package ships both a
/// Deployment and a Job, the Deployment wins.
const WORKLOAD_KINDS: &[&str] = &["Deployment", "StatefulSet", "DaemonSet"];

/// Build the cluster, locate the package instance, and resolve it to a
/// single workload target. Errors are shaped so a caller can print them
/// directly to the user without extra context.
pub fn resolve_package_workload(
    flake_path: &Path,
    cluster: &str,
    package: &str,
    input_overrides: &[(String, String)],
    quiet: bool,
) -> Result<WorkloadTarget> {
    let status = |msg: &str| {
        if !quiet {
            eprintln!("  {msg}");
        }
    };
    if !quiet {
        eprintln!("Building cluster '{cluster}'...");
    }
    let result_path =
        build_cluster_activation_with_status(flake_path, cluster, input_overrides, &status)
            .map_err(|e| miette!("failed to build cluster activation: {e}"))?;

    let mut graph = StoreGraph::from_result_dir_with_status(&result_path, &status)
        .map_err(|e| miette!("failed to load store graph: {e}"))?;
    // Stamp so downstream labels are in the same shape as deploy.
    stamp_annotations(&mut graph);

    let pkg = find_package(&graph, package)?;
    resolve_workload_in_package(&graph, pkg)
}

/// Match a package by instance name. Matches are case-sensitive and prefer
/// the shortest `<namespace>/<instance>` key that ends with the query — so
/// `kix logs ludo vaultwarden` works even when there are multiple namespaces.
fn find_package<'a>(graph: &'a StoreGraph, query: &str) -> Result<&'a PackageNode> {
    // Exact instance-name match first.
    let exact: Vec<_> = graph
        .packages
        .values()
        .filter(|p| p.instance_name == query)
        .collect();
    if exact.len() == 1 {
        return Ok(exact[0]);
    }
    if exact.len() > 1 {
        let choices: Vec<String> = exact
            .iter()
            .map(|p| format!("{}/{}", p.namespace, p.instance_name))
            .collect();
        return Err(miette!(
            "package '{}' is ambiguous — matches: {}. \
             Qualify with <namespace>/<name>.",
            query,
            choices.join(", ")
        ));
    }

    // Qualified "namespace/name" form.
    if let Some((ns, name)) = query.split_once('/') {
        let qual: Vec<_> = graph
            .packages
            .values()
            .filter(|p| p.namespace == ns && p.instance_name == name)
            .collect();
        if qual.len() == 1 {
            return Ok(qual[0]);
        }
    }

    let mut available: Vec<String> = graph
        .packages
        .values()
        .map(|p| format!("{}/{}", p.namespace, p.instance_name))
        .collect();
    available.sort();
    Err(miette!(
        "package '{}' not found in cluster. Available packages: {}",
        query,
        available.join(", ")
    ))
}

fn resolve_workload_in_package(graph: &StoreGraph, pkg: &PackageNode) -> Result<WorkloadTarget> {
    // Iterate resource paths in their declared order and return the first
    // hit at each preferred kind, outer-loop over kinds so Deployment wins
    // over StatefulSet even if the graph interleaves them.
    for kind in WORKLOAD_KINDS {
        if let Some(target) = pkg
            .resource_paths
            .iter()
            .filter_map(|path| graph.resources.get(path))
            .find_map(|r| workload_from_manifest(&r.manifest, kind))
        {
            return Ok(target);
        }
    }

    Err(miette!(
        "package '{}/{}' has no Deployment, StatefulSet, or DaemonSet — nothing to tail logs for. \
         If this package exposes logs via a custom kind, open an issue.",
        pkg.namespace,
        pkg.instance_name
    ))
}

/// Extract a `WorkloadTarget` from a manifest iff its `kind` matches `want`.
fn workload_from_manifest(manifest: &Value, want: &str) -> Option<WorkloadTarget> {
    let kind = manifest.pointer("/kind")?.as_str()?;
    if kind != want {
        return None;
    }
    let name = manifest.pointer("/metadata/name")?.as_str()?.to_string();
    let namespace = manifest
        .pointer("/metadata/namespace")?
        .as_str()?
        .to_string();
    let match_labels = manifest
        .pointer("/spec/selector/matchLabels")?
        .as_object()?;
    if match_labels.is_empty() {
        return None;
    }
    let selector = selector_from_match_labels(match_labels);
    Some(WorkloadTarget {
        kind: kind.to_string(),
        namespace,
        name,
        selector,
    })
}

/// Render `matchLabels` as a `key1=val1,key2=val2` string in sorted key order.
fn selector_from_match_labels(labels: &serde_json::Map<String, Value>) -> String {
    let mut parts: Vec<(&String, String)> = labels
        .iter()
        .filter_map(|(k, v)| v.as_str().map(|s| (k, s.to_string())))
        .collect();
    parts.sort_by(|a, b| a.0.cmp(b.0));
    parts
        .into_iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join(",")
}

/// Resolve a flake ref / path to a usable `PathBuf` for evaluation. Matches
/// the helper used by other commands.
pub fn resolve_flake_path(flake: &str) -> Result<PathBuf> {
    if flake.contains(':') {
        Ok(PathBuf::from(flake))
    } else {
        let path = PathBuf::from(flake);
        if path.is_absolute() {
            Ok(path)
        } else {
            let cwd = std::env::current_dir().into_diagnostic()?;
            Ok(cwd.join(path))
        }
    }
}
