//! The `Plan` document: the one output shape of `kix plan` and `kix diff`.
//!
//! Both commands build a [`Plan`] and hand it to the same renderers, so a
//! consumer (Kix Enterprise, a CI comment, a script) can read either without
//! knowing which ran. `made_by` says how the document was made, and every
//! check the command could not run is [`Checked::NotChecked`] with a reason,
//! never an empty list, so "no conflicts" and "did not look for conflicts"
//! read differently.
//!
//! The JSON Schema of this type is committed at
//! `kix-cli/schema/plan.schema.json`; a test fails when the type and the file
//! disagree. Bump [`SCHEMA_VERSION`] when a change is not backward
//! compatible: a field removed or renamed, or a value's meaning changed.

use std::collections::HashMap;

use kix::cluster::migrate::MigrationPair;
use kix::manifest::diff::{DiffKind, Difference};
use kix::manifest::types::ResourceId;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::origin::ChangeLabel;
use super::{PackageChangeDiff, PackageDiff, PackageInfo};

/// Version of the document's shape. Readers should refuse a version they do
/// not know.
pub const SCHEMA_VERSION: u32 = 1;

/// What a deploy of a build would change, or how two things differ.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Plan {
    pub schema_version: u32,
    pub made_by: MadeBy,
    /// The name the build gives the Kix cluster, which its records carry.
    pub cluster: String,
    pub packages: Packages,
    /// Stateful resources the change removes and adds in the same slot. A
    /// deploy stops on them unless run with `--accept-migrations`.
    pub migrations: Checked<Migration>,
    /// Fields another field manager owns that the apply would set.
    pub conflicts: Checked<Conflict>,
    /// Writes the apiserver, an admission webhook or the deploy itself would
    /// refuse, other than ownership conflicts.
    pub admission: Checked<AdmissionRefusal>,
    /// Fields where the live cluster differs from the deployed build and
    /// that this change touches.
    pub drift: Checked<DriftChange>,
    /// Resources that leave the build, and what the deploy does with each.
    pub prune: Checked<PruneEntry>,
    /// Objects the dry run could not check, and why. Their entries in
    /// `packages` come from comparing builds. Empty unless `made_by` is
    /// `dry_run`.
    pub not_checked: Vec<UncheckedObject>,
    /// Whether Pods start, pull their images, and pass their probes. No
    /// preview can tell, so this is always `not_checked`.
    pub readiness: Checked<String>,
}

/// How a [`Plan`] was made, which bounds what it can know.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum MadeBy {
    /// `kix plan`: the deploy pipeline ran as a server-side dry run, so field
    /// changes are what the apiserver says each write would produce.
    DryRun,
    /// `kix diff` against the live cluster or a snapshot: a read-only
    /// comparison with the kix-owned view.
    LiveRead,
    /// Two builds compared, with no cluster access.
    Builds,
}

/// The result of one check, or why it did not run.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum Checked<T> {
    /// The check ran; `items` is what it found, possibly nothing.
    Checked { items: Vec<T> },
    /// The check did not run.
    NotChecked { reason: NotCheckedReason },
}

impl<T> Checked<T> {
    pub fn items(&self) -> &[T] {
        match self {
            Checked::Checked { items } => items,
            Checked::NotChecked { .. } => &[],
        }
    }

    pub fn not_checked(reason: NotCheckedReason) -> Self {
        Checked::NotChecked { reason }
    }

    pub fn found(items: Vec<T>) -> Self {
        Checked::Checked { items }
    }
}

/// Why a check did not run, so a reader knows how to get it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum NotCheckedReason {
    /// Two builds were compared and no cluster was read. `kix plan` against
    /// the cluster checks it.
    BuildsOnly,
    /// A read-only comparison cannot see it: it shows only on the write
    /// path. `kix plan` checks it.
    ReadOnly,
    /// The deployed build's manifests are not on this machine, so a change
    /// the commit makes cannot be told apart from drift.
    DeployedBuildUnavailable,
    /// No preview can tell.
    NotPreviewable,
}

/// The package-grouped changes, as `kix diff -o json` has always printed
/// them under `packages`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Packages {
    pub added: Vec<PackageEntry>,
    pub removed: Vec<PackageEntry>,
    pub changed: Vec<ChangedPackage>,
    /// Resources outside any package (Namespaces, CRDs, cluster-scoped
    /// bundles) that differ. Keyed `_cluster`.
    pub cluster_level: Option<ChangedPackage>,
    /// The deploy record's name, old to new. `None` when both sides name the
    /// same record.
    pub activation: Option<ActivationChange>,
    pub unchanged: usize,
    pub summary: Summary,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct PackageEntry {
    /// `namespace/name`.
    pub key: String,
    pub version: Option<String>,
    /// Every resource of the package, including `kept_resources`.
    pub resources: usize,
    /// For a removed package, the resources that stay on the cluster.
    pub kept_resources: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ChangedPackage {
    pub key: String,
    pub old_version: Option<String>,
    pub new_version: Option<String>,
    pub added_resources: Vec<String>,
    pub removed_resources: Vec<String>,
    /// Resources that left the build that no prune deletes: Namespaces,
    /// CRDs, and objects another Kix cluster's current build contains.
    pub kept_resources: Vec<String>,
    pub modified_resources: Vec<ModifiedResource>,
    /// Resources whose only change is a dependency's propagated hash.
    pub dep_affected_resources: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ModifiedResource {
    pub resource: String,
    pub diff_count: usize,
    pub changes: Vec<FieldChange>,
}

/// One field change, old to new. A secret value reads
/// [`super::SECRET_NOT_SHOWN`]; a value over [`super::MAX_SHOWN_VALUE_BYTES`]
/// reads `"(N bytes, not shown)"`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct FieldChange {
    pub path: String,
    pub change: ChangeKind,
    /// Absent when the old side has no value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub old: Option<Value>,
    /// Absent when the new side has no value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new: Option<Value>,
    /// What made the change. Absent when the deployed build was not
    /// available to compare with.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub labels: Option<Vec<ChangeLabel>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ChangeKind {
    Added,
    Removed,
    Changed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ActivationChange {
    pub old: Option<String>,
    pub new: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Summary {
    pub added: usize,
    pub removed: usize,
    pub changed: usize,
    pub unchanged: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Migration {
    /// `namespace/instance`.
    pub slot: String,
    pub source: String,
    pub target: String,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Conflict {
    pub resource: String,
    pub owners: Vec<ConflictOwner>,
    /// The apiserver's message.
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ConflictOwner {
    pub manager: String,
    pub fields: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct AdmissionRefusal {
    pub resource: String,
    pub reason: RefusalReason,
    /// The admission webhook that answered, when one did.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub webhook: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum RefusalReason {
    /// An admission webhook denied the write.
    WebhookDenied,
    /// The object fails validation: schema or a CRD's rules.
    Invalid,
    /// A changed field cannot be modified; the object must be deleted and
    /// created again.
    ImmutableField,
    /// RBAC or an admission plugin forbids the write.
    Forbidden,
    /// The namespace does not exist and the build does not create it.
    NamespaceMissing,
    /// The apiserver does not serve the kind and the build has no CRD for it.
    UnknownKind,
    /// A SOPS Secret could not be decrypted.
    Decryption,
    /// The deploy refuses it before sending, or the apiserver gave another
    /// error.
    Other,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct DriftChange {
    pub resource: String,
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deployed: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub live: Option<Value>,
    /// Field managers other than Kix that own the field live. Empty when
    /// Kubernetes recorded no other owner.
    pub managers: Vec<String>,
    /// The deploy applies this object and puts the deployed value back.
    /// False when it leaves the object alone (its identity hash did not
    /// change).
    pub reverted: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct PruneEntry {
    pub resource: String,
    pub fate: PruneFate,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum PruneFate {
    /// Deleted (`--prune`); the dry-run delete was accepted.
    Delete,
    /// `--prune` would delete it, but the dry-run delete was refused.
    DeleteRefused,
    /// Kept by a deploy without `--prune`, and recorded on the new
    /// activation for a later `--prune` or `kix gc`.
    KeptWarnOnly,
    /// Kept by `--prune-mode=no`.
    KeptSkipped,
    /// A Namespace or CRD: never deleted automatically.
    KeptNeverPruned,
    /// Another Kix cluster's current build contains it.
    KeptShared,
    /// It changed since it was read; the next prune checks it again.
    KeptChanged,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct UncheckedObject {
    pub resource: String,
    pub reason: UncheckedReason,
    pub detail: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum UncheckedReason {
    /// Its kind comes from a CRD this deploy creates.
    CrdCreatedByThisDeploy,
    /// Its namespace is created by this deploy.
    NamespaceCreatedByThisDeploy,
    /// An admission webhook that would be called does not support dry run.
    WebhookNoDryRun,
    /// An object it depends on was refused or not checked, so the engine did
    /// not try it.
    DependencyNotChecked,
}

impl Plan {
    /// A plan with every check not run for `reason`, migrations aside.
    pub fn new(
        made_by: MadeBy,
        cluster: &str,
        packages: &PackageDiff,
        migrations: &[MigrationPair],
        reason: NotCheckedReason,
    ) -> Plan {
        Plan {
            schema_version: SCHEMA_VERSION,
            made_by,
            cluster: cluster.to_string(),
            packages: Packages::from(packages),
            migrations: Checked::found(migrations.iter().map(Migration::from).collect()),
            conflicts: Checked::not_checked(reason),
            admission: Checked::not_checked(reason),
            drift: Checked::not_checked(reason),
            prune: Checked::not_checked(reason),
            not_checked: Vec::new(),
            readiness: Checked::not_checked(NotCheckedReason::NotPreviewable),
        }
    }

    /// Anything a deploy would change or stop on.
    pub fn has_changes(&self) -> bool {
        let p = &self.packages;
        !p.added.is_empty()
            || !p.removed.is_empty()
            || !p.changed.is_empty()
            || p.cluster_level.is_some()
            || p.activation.is_some()
            || !self.migrations.items().is_empty()
            || self.stops()
    }

    /// A deploy would refuse or stop on something here: a conflict, a
    /// refused write, or a refused prune delete. Migrations are reported
    /// apart because `--accept-migrations` lets them through.
    pub fn stops(&self) -> bool {
        !self.conflicts.items().is_empty()
            || !self.admission.items().is_empty()
            || self
                .prune
                .items()
                .iter()
                .any(|p| p.fate == PruneFate::DeleteRefused)
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).expect("a Plan serializes")
    }

    pub fn to_yaml(&self) -> Result<String, serde_yml::Error> {
        serde_yml::to_string(self)
    }
}

/// The JSON Schema of [`Plan`], as committed.
#[cfg(test)]
pub fn schema() -> Value {
    serde_json::to_value(schemars::schema_for!(Plan)).expect("a schema serializes")
}

impl From<&MigrationPair> for Migration {
    fn from(p: &MigrationPair) -> Self {
        Migration {
            slot: p.slot.clone(),
            source: p.source.display_id(),
            target: p.target.display_id(),
            reason: p.reason.clone(),
        }
    }
}

impl From<&PackageDiff> for Packages {
    fn from(diff: &PackageDiff) -> Self {
        let labels = diff.labelled.then_some(&diff.labels);
        Packages {
            added: diff.added.iter().map(PackageEntry::from).collect(),
            removed: diff.removed.iter().map(PackageEntry::from).collect(),
            changed: diff
                .changed
                .iter()
                .map(|c| ChangedPackage::of(c, labels))
                .collect(),
            cluster_level: diff
                .cluster_level
                .as_ref()
                .map(|c| ChangedPackage::of(c, labels)),
            activation: diff.activation.as_ref().map(|a| ActivationChange {
                old: a.old.clone(),
                new: a.new.clone(),
            }),
            unchanged: diff.unchanged,
            summary: Summary {
                added: diff.added.len(),
                removed: diff.removed.len(),
                changed: diff.changed.len(),
                unchanged: diff.unchanged,
            },
        }
    }
}

impl From<&PackageInfo> for PackageEntry {
    fn from(p: &PackageInfo) -> Self {
        PackageEntry {
            key: p.key.clone(),
            version: p.version.clone(),
            resources: p.resource_count,
            kept_resources: p.kept.iter().map(|id| id.display_id()).collect(),
        }
    }
}

impl ChangedPackage {
    fn of(
        c: &PackageChangeDiff,
        labels: Option<&HashMap<ResourceId, Vec<Vec<ChangeLabel>>>>,
    ) -> Self {
        let (removed, kept) = c.removed_and_kept();
        ChangedPackage {
            key: c.key.clone(),
            old_version: c.old_version.clone(),
            new_version: c.new_version.clone(),
            added_resources: c.added_resources.iter().map(|id| id.display_id()).collect(),
            removed_resources: removed.iter().map(|id| id.display_id()).collect(),
            kept_resources: kept.iter().map(|id| id.display_id()).collect(),
            modified_resources: c
                .resource_diffs
                .iter()
                .map(|(id, diffs)| {
                    let resource_labels = labels.map(|l| l.get(id));
                    ModifiedResource {
                        resource: id.display_id(),
                        diff_count: diffs.len(),
                        changes: diffs
                            .iter()
                            .enumerate()
                            .map(|(i, d)| {
                                let mut change = FieldChange::of(id, d);
                                change.labels = resource_labels
                                    .map(|l| l.and_then(|l| l.get(i)).cloned().unwrap_or_default());
                                change
                            })
                            .collect(),
                    }
                })
                .collect(),
            dep_affected_resources: c
                .dep_affected_resources
                .iter()
                .map(|id| id.display_id())
                .collect(),
        }
    }
}

impl FieldChange {
    /// `d` with every secret value in it hidden. Other values are shown as
    /// the build and the cluster hold them: a password written as a literal
    /// container `env` value, or into a ConfigMap, is not recognised as
    /// secret.
    pub fn of(id: &ResourceId, d: &Difference) -> Self {
        let change = match d.kind {
            DiffKind::MissingInB => ChangeKind::Removed,
            DiffKind::ExtraInB => ChangeKind::Added,
            DiffKind::ValueMismatch | DiffKind::TypeMismatch => ChangeKind::Changed,
        };
        let is_secret = id.kind == "Secret";
        let shown = |v: &Option<Value>| {
            v.as_ref()
                .map(|v| super::shown_value(is_secret, &d.path, v))
        };
        FieldChange {
            path: d.path.clone(),
            change,
            old: shown(&d.a_value),
            new: shown(&d.b_value),
            labels: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Where the committed schema lives, relative to this crate.
    const SCHEMA_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/schema/plan.schema.json");

    /// The committed schema is the type's schema. Regenerate it with
    /// `KIX_WRITE_PLAN_SCHEMA=1 cargo test -p kix-cli plan::document`, and
    /// bump `SCHEMA_VERSION` when the change is not backward compatible.
    #[test]
    fn the_committed_schema_matches_the_type() {
        let generated = serde_json::to_string_pretty(&schema()).unwrap() + "\n";
        if std::env::var_os("KIX_WRITE_PLAN_SCHEMA").is_some() {
            std::fs::create_dir_all(std::path::Path::new(SCHEMA_PATH).parent().unwrap()).unwrap();
            std::fs::write(SCHEMA_PATH, &generated).unwrap();
        }
        let committed = std::fs::read_to_string(SCHEMA_PATH).unwrap_or_default();
        assert!(
            committed == generated,
            "kix-cli/schema/plan.schema.json does not match the Plan type. \
             Regenerate it with KIX_WRITE_PLAN_SCHEMA=1 cargo test -p kix-cli plan::document \
             and bump SCHEMA_VERSION if the change is not backward compatible."
        );
    }

    #[test]
    fn checked_and_not_checked_read_differently() {
        let none: Checked<Conflict> = Checked::found(Vec::new());
        let unknown: Checked<Conflict> = Checked::not_checked(NotCheckedReason::ReadOnly);
        assert_eq!(
            serde_json::to_value(&none).unwrap(),
            serde_json::json!({"status": "checked", "items": []})
        );
        assert_eq!(
            serde_json::to_value(&unknown).unwrap(),
            serde_json::json!({"status": "not_checked", "reason": "read_only"})
        );
    }
}
