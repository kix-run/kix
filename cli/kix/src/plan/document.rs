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
//! `kix-cli/schema/plan.schema.json`, beside the CLI that prints the
//! document; a test there fails when the type and the file disagree. Set [`SCHEMA_VERSION`] to the day's date when a change is not
//! backward compatible: a field removed or renamed, or a value's meaning
//! changed.

use std::collections::{BTreeMap, HashMap};

pub use crate::cluster::kept::NotKept;
use crate::cluster::migrate::MigrationPair;
use crate::cluster::scheduler::PrunePolicy;
use crate::eval::store_graph::StoreGraph;
use crate::manifest::diff::{DiffKind, Difference};
use crate::manifest::types::ResourceId;
use crate::manifest::{keys, lifecycle};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::origin::ChangeLabel;
use super::{ManifestIndex, PackageChangeDiff, PackageDiff, PackageInfo, Side};

/// Version of the document's shape: the date, `YYYY-MM-DD`, of its last
/// change that was not backward compatible. Readers should refuse a version
/// they do not know.
pub const SCHEMA_VERSION: &str = "2026-11-14";

/// What a deploy of a build would change, or how two things differ.
///
/// Later versions of Kix may add fields. Skip the ones you do not know.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Plan {
    /// The date, `YYYY-MM-DD`, of the document shape's last change that was
    /// not backward compatible.
    pub schema_version: String,
    pub made_by: MadeBy,
    /// The Kix that made the plan.
    pub kix: KixBuild,
    /// The name the build gives the Kix cluster, which its records carry.
    pub cluster: String,
    /// The build the plan is for: the new side.
    pub build: Build,
    /// The build the plan compares against: the cluster's current
    /// Activation record for `kix plan` (also with `--read-only`), the cached
    /// record under `--offline`, the `--from` build,
    /// or the Activation record in a `--from` snapshot. `null` when there is
    /// none: a first deploy, or a snapshot without a record.
    pub deployed: Option<DeployedBuild>,
    /// The flags that change what the planned deploy writes or deletes.
    /// `null` from `kix diff`, which plans no deploy.
    pub flags: Option<PlanFlags>,
    pub packages: Packages,
    /// [`super::objects::digest`] of `objects`. `kix deploy --plan` refuses
    /// a deploy whose objects have another digest. `null` from `kix diff`.
    pub objects_digest: Option<String>,
    /// Every object the planned deploy writes or deletes. `packages` shows
    /// each of them but the re-applied ones; see [`super::objects`]. `null`
    /// from `kix diff`, which plans no deploy.
    pub objects: Option<Objects>,
    /// Stateful resources the change removes and adds in the same slot. A
    /// deploy stops on them unless run with `--accept-migrations`.
    pub migrations: Checked<Migration>,
    /// Fields another field manager owns that the apply would set.
    pub conflicts: Checked<Conflict>,
    /// Writes the apiserver, an admission webhook, or the deploy itself would
    /// refuse, other than ownership conflicts.
    pub admission: Checked<AdmissionRefusal>,
    /// Fields where the live cluster differs from the deployed build. From
    /// `kix plan`, the fields this change touches. From `kix diff` against
    /// the cluster, every field of a drifted object that the new build sets.
    pub drift: Checked<DriftChange>,
    /// How many live objects `kix diff` could not check for drift, because
    /// they have no applied-hash stamp or no Kix field records in
    /// `managedFields`. Left out when there are none.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub drift_unchecked: usize,
    /// Fields the build sets that Kubernetes would not store as sent, from
    /// the dry run of `kix plan`: a field a CRD's schema prunes, or a value
    /// a mutating admission webhook changes. Left out when there are none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub not_kept: Vec<FieldNotKept>,
    /// Resources that leave the build, and what the deploy does with each.
    pub prune: Checked<PruneEntry>,
    /// Objects the dry run could not check, and why. Their entries in
    /// `packages` come from comparing builds. Empty unless `made_by` is
    /// `dry_run`.
    pub not_checked: Vec<UncheckedObject>,
    /// Whether Pods start, pull their images, and pass their probes. No
    /// preview can tell, so this is always `not_checked`.
    pub readiness: Checked<String>,
    /// The Kix library's warnings for the new build, when the command
    /// evaluated it. A build read from a bundle has none. Left out when
    /// there are none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<crate::eval::library_record::LibraryRecord>,
}

fn is_zero(n: &usize) -> bool {
    *n == 0
}

/// The build of Kix that made a plan, so the plan can be checked against
/// the Kix that deploys it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct KixBuild {
    /// The Kix version: the crate version, plus the CI run number as build
    /// metadata in a release build (`0.1.0+250`). A local `cargo build`
    /// reports the bare crate version, which does not change with every
    /// commit.
    pub version: String,
    /// The Nix store path the running binary is in, `null` for a binary
    /// outside the store (a `cargo build`). Two binaries with the same store
    /// path are the same build.
    pub store_path: Option<String>,
}

impl KixBuild {
    /// Return the running binary's [`KixBuild`] with `version` (callers pass
    /// the full [`crate::version::running`] version, build metadata included).
    pub fn current(version: &str) -> Self {
        let store_path = std::env::current_exe()
            .and_then(std::fs::canonicalize)
            .ok()
            .and_then(|exe| store_path_of(&exe.to_string_lossy()));
        KixBuild {
            version: version.to_string(),
            store_path,
        }
    }
}

/// Extract `/nix/store/<hash>-<name>` from a path inside the store.
fn store_path_of(path: &str) -> Option<String> {
    let rest = path.strip_prefix("/nix/store/")?;
    let entry = rest.split('/').next().filter(|e| !e.is_empty())?;
    Some(format!("/nix/store/{entry}"))
}

/// A cluster build.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Build {
    /// The build's store path, the path a deploy records in the
    /// Activation record's `built-via` annotation. It locates the build. It does not identify the
    /// content: two machines can build the same manifests at different
    /// paths.
    pub store_path: String,
    /// The `identity-hash` annotation of the build's Activation record, a hash
    /// of every rendered manifest and what is upstream of it. Two builds with
    /// the same identity hash deploy the same objects. `null` only for a
    /// build without an Activation record.
    pub identity_hash: Option<String>,
}

impl Build {
    pub fn of(graph: &StoreGraph) -> Self {
        let record = graph
            .resources
            .values()
            .map(|node| &node.manifest)
            .find(|m| lifecycle::is_record(m));
        Build {
            store_path: graph.built_via.to_string_lossy().into_owned(),
            identity_hash: record
                .and_then(|r| keys::get(r, keys::IDENTITY_HASH))
                .map(str::to_string),
        }
    }
}

/// The build a cluster runs, as its Activation record names it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct DeployedBuild {
    /// The Activation record's name.
    pub activation: String,
    /// The record's `identity-hash` annotation, as [`Build::identity_hash`].
    pub identity_hash: Option<String>,
    /// The record's `built-via` annotation, when it has one.
    pub store_path: Option<String>,
}

impl DeployedBuild {
    /// Build a [`DeployedBuild`] from an Activation record's manifest, or
    /// return `None` when it has no name.
    pub fn of_record(record: &Value) -> Option<Self> {
        Some(DeployedBuild {
            activation: record.pointer("/metadata/name")?.as_str()?.to_string(),
            identity_hash: keys::get(record, keys::IDENTITY_HASH).map(str::to_string),
            store_path: keys::get(record, keys::BUILT_VIA).map(str::to_string),
        })
    }

    /// Build a [`DeployedBuild`] from the Activation record in `manifests`, if
    /// present.
    pub fn of_manifests(manifests: &[Value]) -> Option<Self> {
        lifecycle::record_of(manifests).and_then(Self::of_record)
    }
}

/// The planning flags of `kix plan` and `kix deploy`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct PlanFlags {
    /// What the deploy does with orphans: `delete` with `--prune`, `skip`
    /// with `--skip-orphan-check`, and `warn_only` otherwise.
    #[serde(with = "prune_field")]
    #[schemars(with = "PruneField")]
    pub prune: PrunePolicy,
    pub reconcile: bool,
    pub force_conflicts: bool,
    pub accept_migrations: bool,
}

impl PlanFlags {
    /// Return the [`PrunePolicy`] that the CLI flags `--prune` and
    /// `--skip-orphan-check` ask for. The CLI refuses both together.
    pub fn prune_policy_of(prune: bool, skip_orphan_check: bool) -> PrunePolicy {
        match (prune, skip_orphan_check) {
            (true, _) => PrunePolicy::Delete,
            (false, true) => PrunePolicy::Skip,
            (false, false) => PrunePolicy::WarnOnly,
        }
    }

    /// Return the CLI flag that asks for `policy`, or `None` for the default.
    pub fn prune_flag(policy: PrunePolicy) -> Option<&'static str> {
        match policy {
            PrunePolicy::Delete => Some("--prune"),
            PrunePolicy::Skip => Some("--skip-orphan-check"),
            PrunePolicy::WarnOnly => None,
        }
    }
}

// The JSON of `PlanFlags::prune`, which a saved plan file keeps. The
// scheduler's `PrunePolicy` maps to it in `prune_field`, so a change to the
// scheduler cannot change the file format without a change here. Its doc
// comment is the schema's description.

/// Policy for handling orphaned resources after all plan nodes terminate.
/// A saved plan records it as `flags.prune`.
#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
#[schemars(rename = "PrunePolicy")]
enum PruneField {
    /// Do not look for orphans at all (`--skip-orphan-check`).
    Skip,
    /// Report orphans and keep them, recorded on the new Activation for a
    /// later `--prune` or `kix gc` (the default).
    WarnOnly,
    /// Delete orphans in reverse-topological order (`--prune`).
    Delete,
}

mod prune_field {
    use super::{PruneField, PrunePolicy};
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S: Serializer>(policy: &PrunePolicy, s: S) -> Result<S::Ok, S::Error> {
        match policy {
            PrunePolicy::Skip => PruneField::Skip,
            PrunePolicy::WarnOnly => PruneField::WarnOnly,
            PrunePolicy::Delete => PruneField::Delete,
        }
        .serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<PrunePolicy, D::Error> {
        Ok(match PruneField::deserialize(d)? {
            PruneField::Skip => PrunePolicy::Skip,
            PruneField::WarnOnly => PrunePolicy::WarnOnly,
            PruneField::Delete => PrunePolicy::Delete,
        })
    }
}

/// How a [`Plan`] was made, which bounds what it can know.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum MadeBy {
    /// `kix plan`: the deploy pipeline ran as a server-side dry run, so field
    /// changes are what the apiserver says each write would produce.
    DryRun,
    /// `kix plan --read-only` against the live cluster, or `kix diff`
    /// against a snapshot: a read-only comparison with the Kix-owned view.
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
    /// Resources outside any package (Namespaces, CRDs, and cluster-scoped
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
    /// At `--detail manifests`: the new manifest of each resource of an
    /// added package, or the old manifest of each resource a removed
    /// package deletes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manifests: Option<BTreeMap<String, ManifestSides>>,
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
    /// At `--detail manifests`: the old and new manifest of each modified,
    /// added, and removed resource. Kept resources are left out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manifests: Option<BTreeMap<String, ManifestSides>>,
}

/// One resource's manifest on each side, hidden as a [`FieldChange`] value
/// is. A manifest over [`super::MAX_SHOWN_MANIFEST_BYTES`] reads
/// `"(N bytes, not shown)"`. `kix plan` shows the live object and the
/// dry-run result of each object the apiserver answered for.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ManifestSides {
    /// Absent when the resource does not exist on the old side.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub old: Option<Value>,
    /// Absent when the resource does not exist on the new side.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ModifiedResource {
    pub resource: String,
    pub diff_count: usize,
    /// Each field change, at `--detail fields` and `--detail manifests`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changes: Option<Vec<FieldChange>>,
}

/// One field change, old to new. A secret value reads
/// [`super::SECRET_NOT_SHOWN`], or [`super::SECRET_CHANGED_NOT_SHOWN`] on the
/// new side when the old side differs; a value over
/// [`super::MAX_SHOWN_VALUE_BYTES`] reads `"(N bytes, not shown)"`.
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

/// The objects a deploy writes and deletes, each list sorted.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Objects {
    pub writes: Vec<ObjectWrite>,
    pub deletes: Vec<ObjectDelete>,
}

/// An object the deploy applies, or may create again (an unchanged Job under
/// the rerun rule, [`WriteChange::IfLastRunFailed`]).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema)]
pub struct ObjectWrite {
    pub kind: String,
    /// `_cluster` for a manifest that gives no namespace.
    pub namespace: String,
    pub name: String,
    /// The hash part of the store path of the build file the object is made
    /// from, which is also its identity hash annotation.
    pub store_hash: String,
    /// The `namespace/instance` of the package `packages` lists the object
    /// under, or `_cluster` for an object no package owns and for the
    /// Activation record.
    pub package: String,
    pub change: WriteChange,
}

impl ObjectWrite {
    /// Return the id of the object written.
    pub fn resource_id(&self) -> ResourceId {
        ResourceId {
            kind: self.kind.clone(),
            namespace: self.namespace.clone(),
            name: self.name.clone(),
        }
    }
}

/// How `packages` shows a write.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum WriteChange {
    /// In an added package, or added to a changed one.
    Added,
    /// Modified.
    Modified,
    /// Changed only in a dependency's propagated hash.
    DepAffected,
    /// Not shown in `packages`: the deployed build, or a deploy of this
    /// cluster that stopped part way, already holds this file for the
    /// object. `--reconcile` writes such objects again, as does a deploy that
    /// repairs what a stopped deploy changed.
    Reapplied,
    /// An unchanged Job under the rerun rule. The deploy reads its last run
    /// and creates it again only if that run failed, so the plan cannot
    /// count it as a write.
    IfLastRunFailed,
}

impl WriteChange {
    /// Return whether the deploy writes the object whatever it finds on the
    /// cluster.
    pub fn certain(self) -> bool {
        self != WriteChange::IfLastRunFailed
    }
}

/// An object the deploy's prune deletes.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema)]
pub struct ObjectDelete {
    pub kind: String,
    pub namespace: String,
    pub name: String,
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
    /// The admission webhook or ValidatingAdmissionPolicy that answered,
    /// when one did.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub webhook: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum RefusalReason {
    /// An admission webhook denied the write.
    WebhookDenied,
    /// A ValidatingAdmissionPolicy denied the write; `webhook` names the
    /// policy.
    PolicyDenied,
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
    /// The apiserver could not reach the Service behind an admission
    /// webhook, so the webhook did not answer. This deploy does not write
    /// that Service or the package that serves it.
    WebhookUnreachable,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct DriftChange {
    pub resource: String,
    /// The field, or `$` for an object whose fields Kix applied changed
    /// although Kubernetes recorded no other owner for any of them.
    pub path: String,
    /// The deployed value. Absent when the deployed manifest does not set
    /// the field or is not on this machine.
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

/// A field the build sets that Kubernetes would not store as sent. A Secret
/// value reads [`super::SECRET_NOT_SHOWN`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct FieldNotKept {
    pub resource: String,
    pub path: String,
    pub change: NotKept,
    /// The value the build sets.
    pub sent: Value,
    /// The value Kubernetes would store. Absent when it drops the field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stored: Option<Value>,
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
    /// Kept by `--skip-orphan-check`.
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
    /// The Namespace, CustomResourceDefinition, or Service whose change by
    /// this deploy makes the answer not final, when Kix knows which.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub because: Option<String>,
    pub detail: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum UncheckedReason {
    /// Its kind comes from a CRD this deploy creates.
    CrdCreatedByThisDeploy,
    /// Its kind's CRD is changed by this deploy, and the dry run checked
    /// the object against the CRD on the cluster now.
    CrdChangedByThisDeploy,
    /// Its namespace is created by this deploy.
    NamespaceCreatedByThisDeploy,
    /// An admission webhook that would be called does not support dry run.
    WebhookNoDryRun,
    /// The engine never reached the object, for example because the dry run
    /// was cancelled. A refused dependency does not cause this: a dry run
    /// still tries the dependents of a refused object.
    DependencyNotChecked,
    /// An admission webhook that would be called could not reach its
    /// Service, and this deploy writes that Service or another object of
    /// the package that owns it.
    WebhookBackendWrittenByThisDeploy,
}

/// How much the `packages` section says about each change.
#[derive(Clone, Copy)]
pub enum Detail<'a> {
    /// Which resources change, and `diff_count` for each modified one.
    Plain,
    /// Also `changes`: each modified resource's field changes.
    Fields,
    /// Also `manifests` on each package entry.
    Manifests(&'a ManifestIndex<'a>),
}

impl Plan {
    /// Construct a [`Plan`] made by `kix`, with all cluster checks except
    /// migrations marked not checked for `reason`.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        kix: KixBuild,
        made_by: MadeBy,
        cluster: &str,
        build: Build,
        packages: &PackageDiff,
        detail: Detail,
        migrations: &[MigrationPair],
        reason: NotCheckedReason,
    ) -> Plan {
        Plan {
            schema_version: SCHEMA_VERSION.to_string(),
            made_by,
            kix,
            cluster: cluster.to_string(),
            build,
            deployed: None,
            flags: None,
            packages: Packages::of(packages, detail),
            objects_digest: None,
            objects: None,
            migrations: Checked::found(migrations.iter().map(Migration::from).collect()),
            conflicts: Checked::not_checked(reason),
            admission: Checked::not_checked(reason),
            drift: Checked::not_checked(reason),
            drift_unchecked: 0,
            not_kept: Vec::new(),
            prune: Checked::not_checked(reason),
            not_checked: Vec::new(),
            readiness: Checked::not_checked(NotCheckedReason::NotPreviewable),
            warnings: Vec::new(),
        }
    }

    /// Return true when a deploy would change or stop on anything, including a
    /// prune delete.
    pub fn has_changes(&self) -> bool {
        let p = &self.packages;
        !p.added.is_empty()
            || !p.removed.is_empty()
            || !p.changed.is_empty()
            || p.cluster_level.is_some()
            || p.activation.is_some()
            || !self.migrations.items().is_empty()
            || self
                .prune
                .items()
                .iter()
                .any(|p| p.fate == PruneFate::Delete)
            || self.stops()
    }

    /// Return true when a deploy would stop on a conflict, a refused write, or
    /// a refused prune delete. Migrations are excluded because
    /// `--accept-migrations` allows them.
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

    pub fn to_yaml(&self) -> Result<String, crate::yaml::SerializeError> {
        crate::yaml::to_string(self)
    }
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

impl Packages {
    pub fn of(diff: &PackageDiff, detail: Detail) -> Self {
        let labels = diff.labelled.then_some(&diff.labels);
        let manifests = match detail {
            Detail::Manifests(index) => Some(index),
            Detail::Plain | Detail::Fields => None,
        };
        let fields = !matches!(detail, Detail::Plain);
        let changed = |c| ChangedPackage::of(c, fields, labels, manifests);
        Packages {
            added: diff
                .added
                .iter()
                .map(|p| PackageEntry::of(p, manifests, Side::New))
                .collect(),
            removed: diff
                .removed
                .iter()
                .map(|p| PackageEntry::of(p, manifests, Side::Old))
                .collect(),
            changed: diff.changed.iter().map(changed).collect(),
            cluster_level: diff.cluster_level.as_ref().map(changed),
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

impl Packages {
    /// Take every package's `manifests` out, leaving the packages as at
    /// `--detail fields`, and give them by object id with the key of the
    /// package that lists them (`_cluster` for `cluster_level`). An object
    /// two packages list moved between them and has the same sides in each;
    /// it carries the package it moves to, not the one that removes it.
    pub fn take_manifests(&mut self) -> BTreeMap<String, (String, ManifestSides)> {
        let mut out: BTreeMap<String, (String, ManifestSides)> = BTreeMap::new();
        let mut put = |key: &str,
                       manifests: Option<BTreeMap<String, ManifestSides>>,
                       removes: &dyn Fn(&str) -> bool| {
            for (id, sides) in manifests.into_iter().flatten() {
                if removes(&id) && out.contains_key(&id) {
                    continue;
                }
                out.insert(id, (key.to_string(), sides));
            }
        };
        for p in &mut self.removed {
            put(&p.key, p.manifests.take(), &|_| true);
        }
        for p in &mut self.added {
            put(&p.key, p.manifests.take(), &|_| false);
        }
        for c in self.changed.iter_mut().chain(self.cluster_level.as_mut()) {
            let removed = c.removed_resources.clone();
            put(&c.key, c.manifests.take(), &|id| {
                removed.iter().any(|r| r == id)
            });
        }
        out
    }

    /// Drop each modified resource's field changes, leaving the packages
    /// as at `--detail plain`.
    pub fn drop_field_changes(&mut self) {
        for c in self.changed.iter_mut().chain(self.cluster_level.as_mut()) {
            for m in &mut c.modified_resources {
                m.changes = None;
            }
        }
    }
}

impl PackageEntry {
    /// Construct a [`PackageEntry`] for `p` on `side` (`Side::New` for an
    /// added package, `Side::Old` for a removed one).
    fn of(p: &PackageInfo, manifests: Option<&ManifestIndex>, side: Side) -> Self {
        PackageEntry {
            key: p.key.clone(),
            version: p.version.clone(),
            resources: p.resource_count,
            kept_resources: p.kept.iter().map(|id| id.display_id()).collect(),
            manifests: manifests.map(|index| {
                let ids: Vec<ResourceId> = index
                    .package_resources(&p.key, side)
                    .into_iter()
                    .filter(|id| !p.kept.contains(id))
                    .collect();
                index.render(&ids)
            }),
        }
    }
}

impl ChangedPackage {
    fn of(
        c: &PackageChangeDiff,
        fields: bool,
        labels: Option<&HashMap<ResourceId, Vec<Vec<ChangeLabel>>>>,
        manifests: Option<&ManifestIndex>,
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
                        changes: fields.then(|| {
                            diffs
                                .iter()
                                .enumerate()
                                .map(|(i, d)| {
                                    let mut change = FieldChange::of(c.secrets.contains(id), d);
                                    change.labels = resource_labels.map(|l| {
                                        l.and_then(|l| l.get(i)).cloned().unwrap_or_default()
                                    });
                                    change
                                })
                                .collect()
                        }),
                    }
                })
                .collect(),
            dep_affected_resources: c
                .dep_affected_resources
                .iter()
                .map(|id| id.display_id())
                .collect(),
            manifests: manifests.map(|index| {
                index.render(
                    c.resource_diffs
                        .iter()
                        .map(|(id, _)| id)
                        .chain(&c.added_resources)
                        .chain(removed.iter().copied()),
                )
            }),
        }
    }
}

impl FieldChange {
    /// Convert `d` into a [`FieldChange`] with secret values redacted.
    /// `is_secret` indicates whether the resource is a Secret
    /// (`types::is_secret`). Values outside Secret fields and `checksum/*`
    /// annotations are shown as stored in the build and cluster.
    pub(crate) fn of(is_secret: bool, d: &Difference) -> Self {
        let change = match d.kind {
            DiffKind::MissingInB => ChangeKind::Removed,
            DiffKind::ExtraInB => ChangeKind::Added,
            DiffKind::ValueMismatch | DiffKind::TypeMismatch => ChangeKind::Changed,
        };
        let max = super::MAX_SHOWN_VALUE_BYTES;
        let old = d.a_value.as_ref();
        FieldChange {
            path: d.path.clone(),
            change,
            old: old.map(|v| super::shown_value(is_secret, &d.path, v, None, max)),
            new: d
                .b_value
                .as_ref()
                .map(|v| super::shown_value(is_secret, &d.path, v, old, max)),
            labels: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_prune_flags_map_to_one_policy() {
        assert_eq!(
            PlanFlags::prune_policy_of(false, false),
            PrunePolicy::WarnOnly
        );
        assert_eq!(PlanFlags::prune_policy_of(true, false), PrunePolicy::Delete);
        assert_eq!(PlanFlags::prune_policy_of(false, true), PrunePolicy::Skip);
        for policy in [
            PrunePolicy::Skip,
            PrunePolicy::WarnOnly,
            PrunePolicy::Delete,
        ] {
            let flag = PlanFlags::prune_flag(policy);
            let back = PlanFlags::prune_policy_of(
                flag == Some("--prune"),
                flag == Some("--skip-orphan-check"),
            );
            assert_eq!(back, policy, "{flag:?}");
        }
    }

    #[test]
    fn the_prune_policy_is_one_field_in_json() {
        for (policy, name) in [
            (PrunePolicy::Skip, "skip"),
            (PrunePolicy::WarnOnly, "warn_only"),
            (PrunePolicy::Delete, "delete"),
        ] {
            let flags = PlanFlags {
                prune: policy,
                reconcile: false,
                force_conflicts: false,
                accept_migrations: false,
            };
            let json = serde_json::to_value(flags).unwrap();
            assert_eq!(
                json,
                serde_json::json!({
                    "prune": name,
                    "reconcile": false,
                    "force_conflicts": false,
                    "accept_migrations": false,
                })
            );
            assert_eq!(serde_json::from_value::<PlanFlags>(json).unwrap(), flags);
        }
    }

    #[test]
    fn a_store_path_is_the_store_entry_of_a_path_inside_it() {
        assert_eq!(
            store_path_of("/nix/store/abc-kix-0.1.0/bin/kix").as_deref(),
            Some("/nix/store/abc-kix-0.1.0")
        );
        assert_eq!(store_path_of("/home/u/target/debug/kix"), None);
        assert_eq!(store_path_of("/nix/store/"), None);
    }

    /// The build and the deployed record are named by their Activation
    /// record's identity hash and store path.
    #[test]
    fn a_plan_names_its_build_and_the_deployed_record() {
        let record = serde_json::json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {"name": "c-1a2b", "annotations": {
                keys::IDENTITY_HASH: "id-old",
                keys::BUILT_VIA: "/nix/store/old-cluster-c",
            }},
        });
        let deployed = DeployedBuild::of_manifests(&[record]).expect("a record");
        assert_eq!(deployed.activation, "c-1a2b");
        assert_eq!(deployed.identity_hash.as_deref(), Some("id-old"));
        assert_eq!(
            deployed.store_path.as_deref(),
            Some("/nix/store/old-cluster-c")
        );
        assert_eq!(DeployedBuild::of_manifests(&[]), None);
    }

    /// A prune delete is a change even when no package changes.
    #[test]
    fn a_prune_delete_alone_is_a_change() {
        let empty = super::super::diff_graphs(
            &crate::eval::store_graph::StoreGraph::empty("c"),
            &crate::eval::store_graph::StoreGraph::empty("c"),
        );
        let mut plan = Plan::new(
            KixBuild::current(&crate::version::running().to_string()),
            MadeBy::DryRun,
            "c",
            Build::of(&crate::eval::store_graph::StoreGraph::empty("c")),
            &empty,
            Detail::Plain,
            &[],
            NotCheckedReason::BuildsOnly,
        );
        assert!(!plan.has_changes());
        let entry = |fate| PruneEntry {
            resource: "ConfigMap/x@app".into(),
            fate,
            detail: None,
        };
        plan.prune = Checked::found(vec![entry(PruneFate::KeptWarnOnly)]);
        assert!(!plan.has_changes());
        plan.prune = Checked::found(vec![entry(PruneFate::Delete)]);
        assert!(plan.has_changes());
        assert!(!plan.stops());
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
