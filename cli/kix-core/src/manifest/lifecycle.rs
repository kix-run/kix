//! Classify manifests by their deployment lifecycle role.
//!
//! A Kix build contains three categories of objects with distinct lifecycle rules:
//!
//! - **Desired** state: workloads and supporting resources. Change detection
//!   diffs them, the scheduler applies them, and pruning deletes any that leave
//!   the build.
//! - **Markers**: `PackageInstance` objects with `kix.run/mode: import`. They
//!   describe an external resource that Kix does not render (such as a
//!   pre-installed `StorageClass` or an out-of-band `Secret`). Readiness polls
//!   the referenced object instead of the marker.
//! - **Records**: the `Activation` resource, one per deploy, recording which
//!   build is live. Its lifecycle is managed by `finalize` and `kix gc`
//!   (superseding older records) rather than by pruning. Because its name
//!   includes the build's identity hash, change detection matches it like any
//!   other resource (an unchanged build is a `Skip`) but never marks an older
//!   `Activation` as a prunable orphan.
//!
//! All classification goes through this module; no other module may compare a
//! kind string directly to `"Activation"` or `"PackageInstance"` (enforced by a
//! test in this module).

use std::collections::HashSet;

use crate::manifest::keys;
use crate::manifest::types::ResourceId;
use serde_json::Value;

/// The kind of the deploy record.
pub const RECORD_KIND: &str = "Activation";
/// The kind that carries import markers (and, without the mode annotation,
/// ordinary package instance records that are desired state like any other).
pub const PACKAGE_INSTANCE_KIND: &str = "PackageInstance";
/// The mode value that marks an import.
pub(crate) const IMPORT_MODE: &str = "import";

/// Activation phase values (stored in status.phase).
pub const PHASE_QUEUED: &str = "Queued";
pub const PHASE_ACTIVE: &str = "Active";
pub const PHASE_SUPERSEDED: &str = "Superseded";
pub const PHASE_DEPLOYING: &str = "Deploying";
/// Deploy completed but some resources failed to apply or become ready.
/// Treated as the "current state" for diffing/drift purposes: the next deploy
/// must be able to find this CR to compute a meaningful plan.
pub const PHASE_DEGRADED: &str = "Degraded";
/// The deploy stopped before it could finalize: cancelled, a node failed under
/// a Stop policy, discovery broke, or the process died and something later
/// marked the record.
///
/// Terminal and never a current state.
/// [`Records::active`](crate::cluster::activation::Records::active) must not
/// return one: a half-applied closure is not what the cluster is running, and
/// diffing against it would compute every object only the still-Active closure
/// has as an orphan. The next deploy reads it only as an extra baseline, to
/// re-apply what it may have changed and prune what it left behind, and
/// supersedes it once that plan finalizes.
pub const PHASE_FAILED: &str = "Failed";

/// How kix treats a manifest. See the module docs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Lifecycle {
    /// Diffed, applied, pruned.
    Desired,
    /// Applied; readiness verifies the object it describes; never pruned
    /// by content (it has no content of its own).
    Marker,
    /// Applied once at the end of a deploy; superseded, never pruned.
    Record,
}

impl Lifecycle {
    /// Return whether an object of this lifecycle role can be pruned when it
    /// leaves the build. Only desired resources and markers are prunable;
    /// `Activation` records are superseded instead.
    pub fn prunable(self) -> bool {
        !matches!(self, Lifecycle::Record)
    }
}

/// Classify a resource from its kind and `kix.run/mode` annotation.
pub fn classify(kind: &str, mode: Option<&str>) -> Lifecycle {
    if kind == RECORD_KIND {
        Lifecycle::Record
    } else if kind == PACKAGE_INSTANCE_KIND && mode == Some(IMPORT_MODE) {
        Lifecycle::Marker
    } else {
        Lifecycle::Desired
    }
}

/// Return whether `kind` is the `Activation` record kind.
pub fn is_record_kind(kind: &str) -> bool {
    kind == RECORD_KIND
}

/// Classify a rendered manifest.
pub fn lifecycle_of(manifest: &Value) -> Lifecycle {
    let kind = manifest.get("kind").and_then(Value::as_str).unwrap_or("");
    let mode = manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(keys::MODE))
        .and_then(Value::as_str);
    classify(kind, mode)
}

/// Return whether `manifest` is the deploy record (`Activation`).
pub fn is_record(manifest: &Value) -> bool {
    lifecycle_of(manifest) == Lifecycle::Record
}

/// Return whether `manifest` is an import marker.
pub fn is_marker(manifest: &Value) -> bool {
    lifecycle_of(manifest) == Lifecycle::Marker
}

/// Return the deploy record in `manifests`, if present.
pub fn record_of(manifests: &[Value]) -> Option<&Value> {
    manifests.iter().find(|m| is_record(m))
}

/// Return whether `kind` is a Kix-internal bookkeeping kind (`Activation` or
/// `PackageInstance`) that `kix export --for=exit` omits.
pub fn is_kix_internal_kind(kind: &str) -> bool {
    kind == RECORD_KIND || kind == PACKAGE_INSTANCE_KIND
}

/// Return whether `kind` is reported as an orphan when it leaves the build but
/// never deleted automatically (`Namespace` and `CustomResourceDefinition`).
///
/// Deleting a `Namespace` deletes every object inside it, and deleting a
/// `CustomResourceDefinition` deletes every custom resource of that kind across
/// the cluster, including resources Kix does not manage. Deploy pruning, all
/// `kix gc` modes, and operator teardown consult this predicate and leave
/// deletion to an explicit `kubectl delete`.
pub fn never_pruned(kind: &str) -> bool {
    matches!(kind, "Namespace" | "CustomResourceDefinition")
}

/// Return the platform Kix cluster name for a consumer `Activation` record
/// (from `spec.interfaces`), or `None` if the record does not belong to a
/// consumer cluster.
pub fn platform_of(record: &Value) -> Option<&str> {
    record
        .pointer("/spec/interfaces")
        .and_then(Value::as_object)
        .and_then(|interfaces| interfaces.keys().next())
        .map(String::as_str)
}

/// Return whether `manifest` is one of Kix's own CustomResourceDefinitions.
pub fn is_kix_crd(manifest: &Value) -> bool {
    manifest.get("kind").and_then(Value::as_str) == Some("CustomResourceDefinition")
        && matches!(
            manifest.pointer("/metadata/name").and_then(Value::as_str),
            Some(keys::ACTIVATIONS_CRD | keys::PACKAGE_INSTANCES_CRD)
        )
}

/// Return the resource IDs in `manifests` that belong to the platform rather
/// than the consumer cluster (Kix's own CRDs when the build's record is a
/// consumer record, or an empty set otherwise).
///
/// On a shared Kubernetes cluster, the platform installs Kix's CRDs. A consumer
/// deploy waits for those CRDs and never writes them, so it cannot overwrite
/// the platform's CRD schema.
pub fn left_to_platform<'a>(manifests: impl IntoIterator<Item = &'a Value>) -> HashSet<ResourceId> {
    let manifests: Vec<&Value> = manifests.into_iter().collect();
    if !manifests
        .iter()
        .any(|m| is_record(m) && platform_of(m).is_some())
    {
        return HashSet::new();
    }
    manifests
        .into_iter()
        .filter(|m| is_kix_crd(m))
        .map(ResourceId::from_value)
        .collect()
}

#[cfg(test)]
mod left_to_platform_tests {
    use super::*;
    use serde_json::json;

    fn crd(name: &str) -> Value {
        json!({"apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition",
            "metadata": {"name": name}})
    }

    fn record(spec: Value) -> Value {
        json!({"apiVersion": keys::API_VERSION, "kind": RECORD_KIND,
            "metadata": {"name": "rec"}, "spec": spec})
    }

    #[test]
    fn a_consumer_leaves_kix_crds_to_its_platform() {
        let manifests = [
            crd(keys::ACTIVATIONS_CRD),
            crd(keys::PACKAGE_INSTANCES_CRD),
            crd("widgets.example.com"),
            record(json!({"interfaces": {"platform": {"consumer": "acme"}}})),
        ];
        assert_eq!(platform_of(&manifests[3]), Some("platform"));
        let left = left_to_platform(&manifests);
        let mut names: Vec<&str> = left.iter().map(|id| id.name.as_str()).collect();
        names.sort();
        assert_eq!(names, [keys::ACTIVATIONS_CRD, keys::PACKAGE_INSTANCES_CRD]);
    }

    #[test]
    fn a_cluster_without_interfaces_writes_kix_crds() {
        for spec in [json!({}), json!({"interfaces": {}})] {
            let manifests = [crd(keys::ACTIVATIONS_CRD), record(spec)];
            assert_eq!(platform_of(&manifests[1]), None);
            assert!(left_to_platform(&manifests).is_empty());
        }
    }
}

#[cfg(test)]
mod never_pruned_tests {
    #[test]
    fn namespaces_and_crds_are_kept() {
        assert!(super::never_pruned("Namespace"));
        assert!(super::never_pruned("CustomResourceDefinition"));
    }

    #[test]
    fn ordinary_kinds_are_pruned() {
        for kind in ["Deployment", "Service", "ConfigMap", "Secret", "SGCluster"] {
            assert!(!super::never_pruned(kind), "{kind} should be prunable");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn m(kind: &str, mode: Option<&str>) -> Value {
        let mut v = json!({ "apiVersion": "v1", "kind": kind, "metadata": { "name": "x" } });
        if let Some(mode) = mode {
            v["metadata"]["annotations"] = json!({ keys::MODE: mode });
        }
        v
    }

    #[test]
    fn table() {
        assert_eq!(lifecycle_of(&m("Activation", None)), Lifecycle::Record);
        assert_eq!(
            lifecycle_of(&m("Activation", Some("import"))),
            Lifecycle::Record
        );
        assert_eq!(
            lifecycle_of(&m("PackageInstance", Some("import"))),
            Lifecycle::Marker
        );
        assert_eq!(
            lifecycle_of(&m("PackageInstance", None)),
            Lifecycle::Desired
        );
        assert_eq!(
            lifecycle_of(&m("PackageInstance", Some("normal"))),
            Lifecycle::Desired
        );
        assert_eq!(
            lifecycle_of(&m("Deployment", Some("import"))),
            Lifecycle::Desired
        );
        assert_eq!(lifecycle_of(&json!({})), Lifecycle::Desired);
        assert!(!Lifecycle::Record.prunable());
        assert!(Lifecycle::Marker.prunable());
        assert!(Lifecycle::Desired.prunable());
    }

    #[test]
    fn split_and_find() {
        let set = vec![
            m("Deployment", None),
            m("Activation", None),
            m("PackageInstance", Some("import")),
        ];
        assert_eq!(
            record_of(&set).map(|r| r["kind"].as_str().unwrap()),
            Some("Activation")
        );
        assert_eq!(set.iter().filter(|m| is_record(m)).count(), 1);
        assert!(is_kix_internal_kind("PackageInstance"));
        assert!(!is_kix_internal_kind("Deployment"));
    }

    /// Verify that the record and marker kind strings (`"Activation"` and
    /// `"PackageInstance"`) are spelled only in this module; all other non-test
    /// code across the workspace must use `RECORD_KIND` and
    /// `PACKAGE_INSTANCE_KIND`.
    #[test]
    fn no_other_file_spells_the_record_or_marker_kind() {
        let lib_src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let workspace = lib_src.parent().unwrap().parent().unwrap();
        let roots = [
            lib_src.clone(),
            workspace.join("kix").join("src"),
            workspace.join("kix-cli").join("src"),
            workspace.join("kix-operator").join("src"),
        ];
        let mut offenders = Vec::new();
        let mut scanned = 0usize;
        for root in roots {
            assert!(root.is_dir(), "scan root missing: {}", root.display());
            for path in rust_files(&root) {
                if path.ends_with("lifecycle.rs")
                    || path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n == "tests.rs" || n.ends_with("_tests.rs"))
                {
                    continue;
                }
                scanned += 1;
                let text = std::fs::read_to_string(&path).unwrap();
                for (i, line) in text.lines().enumerate() {
                    if line.trim_start().starts_with("#[cfg(test)]") {
                        break;
                    }
                    let trimmed = line.trim_start();
                    if trimmed.starts_with("//") {
                        continue;
                    }
                    if line.contains("\"Activation\"") || line.contains("\"PackageInstance\"") {
                        offenders.push(format!("{}:{}: {}", path.display(), i + 1, line.trim()));
                    }
                }
            }
        }
        assert!(
            scanned > 50,
            "scan reached only {scanned} files; roots misresolved?"
        );
        assert!(
            offenders.is_empty(),
            "the record or marker kind is spelled outside manifest/lifecycle.rs:\n{}",
            offenders.join("\n")
        );
    }

    fn rust_files(root: &std::path::Path) -> Vec<std::path::PathBuf> {
        let mut out = Vec::new();
        let Ok(entries) = std::fs::read_dir(root) else {
            return out;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                out.extend(rust_files(&path));
            } else if path.extension().is_some_and(|e| e == "rs") {
                out.push(path);
            }
        }
        out
    }
}
