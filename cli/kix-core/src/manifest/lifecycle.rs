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

use crate::manifest::keys;
use crate::manifest::kinds::{self, GroupKind};
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
/// A deploy with `--only` applied every object it selected and stopped,
/// leaving the rest of the build for a later deploy. `status.partial` names
/// the instances it applied.
///
/// Never a current state, for the same reason as [`PHASE_FAILED`]. The next
/// plan folds the record's build into its baseline as it does for a
/// `Failed` record, and the deploy that finalizes supersedes it.
pub const PHASE_PARTIAL: &str = "Partial";

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
/// `PackageInstance`) that `kix export` omits without `--with-kix-metadata`.
pub fn is_kix_internal_kind(kind: &str) -> bool {
    kind == RECORD_KIND || kind == PACKAGE_INSTANCE_KIND
}

/// Return whether `kind` is reported as an orphan when it leaves the build but
/// never deleted automatically (core `Namespace` and
/// `apiextensions.k8s.io` `CustomResourceDefinition`).
///
/// Deleting a `Namespace` deletes every object inside it, and deleting a
/// `CustomResourceDefinition` deletes every custom resource of that kind across
/// the cluster, including resources Kix does not manage. Deploy pruning, all
/// `kix gc` modes, and operator teardown consult this predicate and leave
/// deletion to an explicit `kubectl delete`.
pub fn never_pruned(kind: GroupKind<'_>) -> bool {
    matches!(kind, kinds::NAMESPACE | kinds::CUSTOM_RESOURCE_DEFINITION)
}

/// Return whether `manifest` is the CustomResourceDefinition of Activation or
/// PackageInstance.
///
/// Builds of earlier releases carry these two definitions. The Kix program
/// installs them now (`cluster::own_crds` in `kix-lib`), so every loaded
/// build, live sweep, and snapshot leaves them out. Without that, a build
/// from before the change would put them back on a rollback, and every plan
/// would list them, and the records they hold, as left behind.
pub fn is_kix_crd(manifest: &Value) -> bool {
    is_kix_crd_named(
        GroupKind::of_manifest(manifest),
        manifest.pointer("/metadata/name").and_then(Value::as_str),
    )
}

/// Return whether `kind` and `name` name a definition [`is_kix_crd`] matches.
pub fn is_kix_crd_named(kind: GroupKind<'_>, name: Option<&str>) -> bool {
    kind == kinds::CUSTOM_RESOURCE_DEFINITION
        && matches!(
            name,
            Some(keys::ACTIVATIONS_CRD | keys::PACKAGE_INSTANCES_CRD)
        )
}

#[cfg(test)]
mod kix_crd_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_the_two_record_definitions_match() {
        let crd = |name: &str| {
            json!({"apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition",
                "metadata": {"name": name}})
        };
        assert!(is_kix_crd(&crd(keys::ACTIVATIONS_CRD)));
        assert!(is_kix_crd(&crd(keys::PACKAGE_INSTANCES_CRD)));
        assert!(!is_kix_crd(&crd("widgets.example.com")));
        let record = json!({"apiVersion": keys::API_VERSION, "kind": RECORD_KIND,
            "metadata": {"name": keys::ACTIVATIONS_CRD}});
        assert!(!is_kix_crd(&record));
    }
}

#[cfg(test)]
mod never_pruned_tests {
    use crate::manifest::kinds::{self, GroupKind};

    #[test]
    fn namespaces_and_crds_are_kept() {
        assert!(super::never_pruned(kinds::NAMESPACE));
        assert!(super::never_pruned(kinds::CUSTOM_RESOURCE_DEFINITION));
    }

    #[test]
    fn ordinary_kinds_are_pruned() {
        for kind in [
            kinds::DEPLOYMENT,
            kinds::SERVICE,
            kinds::CONFIG_MAP,
            kinds::SECRET,
            GroupKind::new("stackgres.io", "SGCluster"),
        ] {
            assert!(!super::never_pruned(kind), "{kind:?} should be prunable");
        }
    }

    /// A custom resource named like a protected kind is pruned as usual.
    #[test]
    fn a_custom_kind_of_a_protected_name_is_pruned() {
        assert!(!super::never_pruned(GroupKind::new(
            "example.com",
            "Namespace"
        )));
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
