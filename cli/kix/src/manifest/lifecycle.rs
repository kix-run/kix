//! What kind of thing a manifest is, decided once.
//!
//! A kix build contains three kinds of object that look alike on the wire
//! and are nothing alike in how kix treats them:
//!
//! - **Desired** state: the workloads and their supporting resources. Change
//!   detection diffs them, the scheduler applies them, prune deletes the
//!   ones that vanished from the build.
//! - **Markers**: PackageInstance objects with `kix.run/mode: import`. They
//!   describe a resource kix does not render (a StorageClass installed by
//!   hand, a Secret created out of band). Readiness polls for the described
//!   object instead of the marker.
//! - **Records**: the Activation, one per deploy. It records which build is
//!   live. Its lifecycle is supersede-managed by finalize and by `kix gc`,
//!   never by prune. It changes name on every deploy (the identity-hash
//!   suffix), so change detection matches it like any other resource (an
//!   unchanged build is still a Skip) but never lists it as an orphan:
//!   before this module `--prune` deleted last deploy's record before
//!   finalize could mark it Superseded (kixpkgs#59).
//!
//! Before this module the distinction lived in eleven `kind == "Activation"`
//! comparisons across three crates, each a private copy of the same rule,
//! and the store-graph path in deploy had forgotten it. This is the one
//! table. Nothing outside it may compare a kind string to `"Activation"`
//! (a test in this module enforces that).

use std::collections::HashSet;

use crate::manifest::keys;
use crate::manifest::types::ResourceId;
use kube::api::DynamicObject;
use serde_json::Value;

/// The kind of the deploy record.
pub const RECORD_KIND: &str = "Activation";
/// The kind that carries import markers (and, without the mode annotation,
/// ordinary package instance records that are desired state like any other).
pub(crate) const PACKAGE_INSTANCE_KIND: &str = "PackageInstance";
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
    /// Can this thing be an orphan, that is, deleted because it left the
    /// build? Only desired state and markers. Records never.
    pub fn prunable(self) -> bool {
        !matches!(self, Lifecycle::Record)
    }
}

/// Classify from a kind and an annotation lookup. The one place the rule
/// is written; the public functions below adapt manifests and live objects
/// to it.
fn classify(kind: &str, mode: Option<&str>) -> Lifecycle {
    if kind == RECORD_KIND {
        Lifecycle::Record
    } else if kind == PACKAGE_INSTANCE_KIND && mode == Some(IMPORT_MODE) {
        Lifecycle::Marker
    } else {
        Lifecycle::Desired
    }
}

/// Is this kind the record kind? For call sites that hold only a
/// `ResourceId`, not the manifest.
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

/// Classify a live object. LIST responses put the kind either in `.data`
/// (kix injects it there) or in `.types`; annotations live on the typed
/// metadata.
pub fn lifecycle_of_live(obj: &DynamicObject) -> Lifecycle {
    let kind = obj
        .data
        .get("kind")
        .and_then(Value::as_str)
        .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
        .unwrap_or("");
    let mode = obj
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::MODE));
    classify(kind, mode)
}

/// Is this manifest the deploy record?
pub fn is_record(manifest: &Value) -> bool {
    lifecycle_of(manifest) == Lifecycle::Record
}

/// Is this manifest an import marker?
pub(crate) fn is_marker(manifest: &Value) -> bool {
    lifecycle_of(manifest) == Lifecycle::Marker
}

/// Annotations that carry a Helm hook delete policy. Charts imported into a
/// package keep them.
pub(crate) const HOOK_DELETE_POLICY: [&str; 1] = ["helm.sh/hook-delete-policy"];

/// Does this manifest declare that it removes itself once it succeeds?
///
/// Two independent declarations, either of which makes absence expected:
///   * `helm.sh/hook-delete-policy` containing `hook-succeeded` on a manifest
///     rendered from a chart: Helm's convention, kept so imported hooks read
///     the same way. Kix has no hook vocabulary of its own; a Job that
///     must run again is the rerun rule's business (`kix.run/rerun`).
///   * a Job's `spec.ttlSecondsAfterFinished`: Kubernetes' TTL controller
///     deletes it some time after completion.
pub fn declares_own_deletion(manifest: &serde_json::Value) -> bool {
    let annotations = manifest.pointer("/metadata/annotations");
    let deletes_on_success = HOOK_DELETE_POLICY.iter().any(|key| {
        annotations
            .and_then(|a| a.get(*key))
            .and_then(serde_json::Value::as_str)
            .is_some_and(|p| p.split(',').any(|s| s.trim() == "hook-succeeded"))
    });

    let ttl_reaped = manifest.get("kind").and_then(serde_json::Value::as_str) == Some("Job")
        && manifest
            .pointer("/spec/ttlSecondsAfterFinished")
            .is_some_and(serde_json::Value::is_number);

    deletes_on_success || ttl_reaped
}

/// The deploy record in a manifest set, if present. A build carries at most
/// one; the first is returned.
pub fn record_of(manifests: &[Value]) -> Option<&Value> {
    manifests.iter().find(|m| is_record(m))
}

/// Kinds that only make sense inside a live kix deployment. An "exit"
/// export drops them; they would be garbage in a neutral handoff.
pub fn is_kix_internal_kind(kind: &str) -> bool {
    kind == RECORD_KIND || kind == PACKAGE_INSTANCE_KIND
}

/// Kinds that Kix reports when they leave the build but never deletes,
/// because deleting one also deletes resources outside the deployment.
///
/// A Namespace takes every object inside it, whether Kix manages it or not.
/// A CustomResourceDefinition takes every custom resource of that kind in
/// the cluster, including resources Kix does not manage. Deploy's prune,
/// every `kix gc` mode and the operator's teardown all consult this
/// predicate; removing such an object is left to an explicit `kubectl delete`.
pub fn never_pruned(kind: &str) -> bool {
    matches!(kind, "Namespace" | "CustomResourceDefinition")
}

/// The platform Kix cluster whose consumer `record` is, from the interface
/// that platform gave it in `spec.interfaces`. A consumer shares its
/// Kubernetes cluster with that platform and loads one interface. `None`
/// for any other cluster's record.
pub fn platform_of(record: &Value) -> Option<&str> {
    record
        .pointer("/spec/interfaces")
        .and_then(Value::as_object)
        .and_then(|interfaces| interfaces.keys().next())
        .map(String::as_str)
}

/// Whether `manifest` is one of Kix's own CustomResourceDefinitions.
pub fn is_kix_crd(manifest: &Value) -> bool {
    manifest.get("kind").and_then(Value::as_str) == Some("CustomResourceDefinition")
        && matches!(
            manifest.pointer("/metadata/name").and_then(Value::as_str),
            Some(keys::ACTIVATIONS_CRD | keys::PACKAGE_INSTANCES_CRD)
        )
}

/// The objects of a build that its platform writes: Kix's own CRDs when the
/// build's record is a consumer's, and nothing otherwise.
///
/// Every Kix build contains Kix's CRDs, and every Kix cluster applies with
/// the same field manager. On a Kubernetes cluster that a platform shares
/// with its consumers, the platform installs these CRDs. A consumer that
/// applied its own copy would replace the platform's schema without a
/// conflict, and a consumer on another Kix version would change it. So a
/// consumer's deploy waits for them and never writes them.
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

    #[test]
    fn ttl_job_declares_own_deletion() {
        assert!(declares_own_deletion(&json!({
            "kind": "Job",
            "metadata": { "name": "postgres-reflect" },
            "spec": { "ttlSecondsAfterFinished": 600 },
        })));
    }

    #[test]
    fn zero_ttl_still_counts() {
        assert!(declares_own_deletion(&json!({
            "kind": "Job",
            "spec": { "ttlSecondsAfterFinished": 0 },
        })));
    }

    #[test]
    fn hook_succeeded_policy_declares_own_deletion() {
        for key in HOOK_DELETE_POLICY {
            assert!(
                declares_own_deletion(&json!({
                    "kind": "Job",
                    "metadata": { "annotations": { key: "before-hook-creation,hook-succeeded" } },
                })),
                "{key} should be honored"
            );
        }
    }

    #[test]
    fn before_hook_creation_alone_does_not() {
        // Deletion before the next run does not prove that this run succeeded; a job that is
        // absent now is still a job that never ran.
        assert!(!declares_own_deletion(&json!({
            "kind": "Job",
            "metadata": { "annotations": { "helm.sh/hook-delete-policy": "before-hook-creation" } },
        })));
    }

    #[test]
    fn plain_workload_does_not_declare_own_deletion() {
        assert!(!declares_own_deletion(&json!({
            "kind": "Deployment",
            "metadata": { "name": "immich-server" },
            "spec": { "replicas": 1 },
        })));
    }

    #[test]
    fn non_job_with_ttl_field_does_not() {
        // ttlSecondsAfterFinished is a Job field; anything else carrying it
        // is not making the same promise.
        assert!(!declares_own_deletion(&json!({
            "kind": "ConfigMap",
            "spec": { "ttlSecondsAfterFinished": 600 },
        })));
    }

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
    fn live_objects_classify_the_same_way() {
        let mut obj: DynamicObject = serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": { "name": "stage1-abc" }
        }))
        .unwrap();
        assert_eq!(lifecycle_of_live(&obj), Lifecycle::Record);
        // Kind injected into .data by the sweep, types absent.
        obj.types = None;
        obj.data = json!({ "kind": "PackageInstance" });
        obj.metadata.annotations = Some([(keys::MODE.to_string(), "import".to_string())].into());
        assert_eq!(lifecycle_of_live(&obj), Lifecycle::Marker);
        obj.metadata.annotations = None;
        assert_eq!(lifecycle_of_live(&obj), Lifecycle::Desired);
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

    /// Invariant 7 from kixpkgs#59: the kind strings of the record and the
    /// marker are written in exactly one place. Any other non-test line in
    /// the three crates that spells `"Activation"` or `"PackageInstance"` is
    /// a private copy of the rule (a comparison, a match arm, a constructed
    /// object), which is how the phantom orphan happened. Use `RECORD_KIND`
    /// and `PACKAGE_INSTANCE_KIND` instead. Test modules (everything after
    /// the first `#[cfg(test)]` in a file) may use the literals as fixtures.
    #[test]
    fn no_other_file_spells_the_record_or_marker_kind() {
        let lib_src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let workspace = lib_src.parent().unwrap().parent().unwrap();
        let roots = [
            lib_src.clone(),
            workspace.join("kix-cli").join("src"),
            workspace.join("kix-operator").join("src"),
        ];
        let mut offenders = Vec::new();
        let mut scanned = 0usize;
        for root in roots {
            assert!(root.is_dir(), "scan root missing: {}", root.display());
            for path in rust_files(&root) {
                if path.ends_with("lifecycle.rs") {
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
