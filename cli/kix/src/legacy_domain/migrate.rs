//! Moving a cluster's Kix records from a retired API group to the current
//! one, behind `kix migrate domain <cluster>`.
//!
//! # Why it is a command and not part of deploy
//!
//! It deletes CustomResourceDefinitions and rewrites deploy history. Both
//! deserve a person, a dry run and a prompt. The gate in
//! [`super::check_discovery`] is what makes it unmissable: until it has run,
//! every command that reads a Kix record refuses and names it.
//!
//! # Order, and why it is fixed
//!
//! `ResourceId` has no group field and kind lookup in discovery is
//! first-wins, so while `activations.<retired>` and `activations.<current>`
//! both exist, `Activation/_cluster/<name>` names two objects and the CLI
//! cannot say which one it read. The old CRDs therefore go in the same run
//! that creates the new ones.
//!
//! PackageInstance records are not copied. They are in every activation's
//! manifest set, so the deploy that follows re-creates them, import markers
//! included.

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::cluster::activation::{PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING};
use crate::manifest::keys;
use crate::manifest::lifecycle::{PACKAGE_INSTANCE_KIND, RECORD_KIND};

use super::DOMAINS;

/// One of Kix's own record kinds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RecordKind {
    pub kind: &'static str,
    pub plural: &'static str,
    /// Cluster-scoped records have no namespace.
    pub cluster_scoped: bool,
}

/// The activation history. Copied.
pub const ACTIVATION: RecordKind = RecordKind {
    kind: RECORD_KIND,
    plural: "activations",
    cluster_scoped: true,
};

/// The package markers. Re-created by the next deploy, so not copied.
pub const PACKAGE_INSTANCE: RecordKind = RecordKind {
    kind: PACKAGE_INSTANCE_KIND,
    plural: "packageinstances",
    cluster_scoped: false,
};

/// `<plural>.<domain>`, the CRD name.
pub fn crd_name(record: RecordKind, domain: &str) -> String {
    format!("{}.{}", record.plural, domain)
}

/// Everything the migration does to a cluster.
///
/// A trait so the steps can be tested without an apiserver.
/// [`super::KubeMigrationOps`] is the real implementation.
#[async_trait]
pub trait MigrationOps: Send + Sync {
    /// Is this CustomResourceDefinition registered?
    async fn crd_exists(&self, name: &str) -> Result<bool, String>;

    /// Every record of this kind in this group.
    async fn list_records(&self, group: &str, record: RecordKind) -> Result<Vec<Value>, String>;

    /// Server-side apply a CustomResourceDefinition.
    async fn apply_crd(&self, manifest: &Value) -> Result<(), String>;

    /// Wait until the CRD is registered and servable.
    async fn await_crd(&self, name: &str) -> Result<(), String>;

    /// Create one record, without its status.
    async fn create_record(
        &self,
        group: &str,
        record: RecordKind,
        manifest: &Value,
    ) -> Result<(), String>;

    /// Write one record's status through the status subresource.
    async fn set_record_status(
        &self,
        group: &str,
        record: RecordKind,
        name: &str,
        status: &Value,
    ) -> Result<(), String>;

    /// Remove one finalizer from a record, so deleting its CRD does not
    /// leave the record Terminating for ever.
    async fn strip_finalizer(
        &self,
        group: &str,
        record: RecordKind,
        name: &str,
        finalizer: &str,
    ) -> Result<(), String>;

    /// Delete a CustomResourceDefinition, cascading to its records.
    async fn delete_crd(&self, name: &str) -> Result<(), String>;

    /// Wait until the CRD is gone from discovery.
    async fn await_crd_gone(&self, name: &str) -> Result<(), String>;

    /// Pause long enough for a running operator to reconcile a record it
    /// watches. The finalizer probe in `run` writes, waits this long, and
    /// reads back: without the pause a slow operator looks like no operator.
    async fn pause_for_operator(&self);
}

/// What the migration found, and what it did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Report {
    /// The retired group that was found, if any.
    pub from_group: Option<String>,
    /// Activation names, oldest first as the apiserver returned them.
    pub activations: Vec<String>,
    /// Activations already present under the current group, so skipped.
    pub already_present: Vec<String>,
    /// Activations copied by this run.
    pub copied: Vec<String>,
    /// CRDs deleted by this run.
    pub crds_deleted: Vec<String>,
    /// Nothing was written.
    pub dry_run: bool,
    /// A Kix finalizer is on at least one record. On its own this says only
    /// that an operator reconciled the record at some point: the operator
    /// removes its finalizer when the record is deleted and at no other
    /// time, so a record it touched carries one for ever, whether or not
    /// anything is running now. `operator_running` is the answer to the
    /// question this only raises.
    pub finalizers_present: bool,
    /// Records whose phase is Active or Degraded. Exactly one is the
    /// healthy case; `Records::active` takes the most recently deployed,
    /// so more than one means the deploy after this migration may diff
    /// against the wrong build.
    pub current_records: Vec<String>,
}

impl Report {
    /// Nothing to do: no retired group on this cluster.
    pub fn nothing_to_do() -> Self {
        Self::default()
    }

    /// Did this cluster need migrating at all?
    pub fn needed(&self) -> bool {
        self.from_group.is_some()
    }
}

/// Copy the records to the current group and retire the old CRDs.
///
/// `crds` are the two CustomResourceDefinition manifests from the cluster's
/// own build, so the migration installs exactly what the next deploy
/// expects. Under `dry_run` nothing is written and the report says what
/// would be copied.
pub async fn run(ops: &dyn MigrationOps, crds: &[Value], dry_run: bool) -> Result<Report, String> {
    let Some(from_group) = find_legacy_group(ops).await? else {
        return Ok(Report::nothing_to_do());
    };

    let mut report = Report {
        from_group: Some(from_group.clone()),
        dry_run,
        ..Report::default()
    };

    // `find_legacy_group` accepts either CRD, so that a run which deleted one
    // and then died leaves a cluster the next run still recognises. Listing
    // activations when that is the CRD already gone would 404 and fail the
    // command, dry run included, without clearing the one still stranded.
    // There is nothing to copy in that state; the remaining work is the
    // delete at the end.
    let old_crd_present = ops.crd_exists(&crd_name(ACTIVATION, &from_group)).await?;
    let old = if old_crd_present {
        ops.list_records(&from_group, ACTIVATION).await?
    } else {
        Vec::new()
    };
    report.activations = old.iter().filter_map(name_of).map(str::to_string).collect();

    if let Some(busy) = old.iter().find(|r| phase_of(r) == Some(PHASE_DEPLOYING)) {
        let name = name_of(busy).unwrap_or("<unnamed>");
        // A record left Deploying by a run that was killed never finishes on
        // its own, so "wait" would be a refusal with no way out. Name the
        // patch that clears it.
        return Err(format!(
            "activation {name} is still deploying. If a deploy is running, wait for it \
             to finish and run this again.\n\
             If nothing is running, that record was left behind by a deploy that was \
             killed. Clear it with:\n  \
             kubectl patch {}/{name} --subresource=status --type=merge \
             -p '{{\"status\":{{\"phase\":\"Superseded\"}}}}'",
            crd_name(ACTIVATION, &from_group),
        ));
    }

    report.current_records = old
        .iter()
        .filter(|r| matches!(phase_of(r), Some(PHASE_ACTIVE | PHASE_DEGRADED)))
        .filter_map(name_of)
        .map(str::to_string)
        .collect();

    // A finalizer on a PackageInstance would wedge this beyond repair.
    //
    // Deleting the CRD cascades to its records, and a record with a
    // finalizer nobody will clear stays Terminating, so the CRD never goes
    // and the cluster is left with both groups live. Every command refuses
    // that state, and a rerun of this one wedges in the same place. The
    // migration cannot clear it either: PackageInstances are namespaced and
    // `writable` only addresses cluster-scoped records. So this looks
    // before it is too late, and names the fix.
    if ops
        .crd_exists(&crd_name(PACKAGE_INSTANCE, &from_group))
        .await?
    {
        let markers = ops.list_records(&from_group, PACKAGE_INSTANCE).await?;
        if let Some(held) = markers.iter().find(|r| has_legacy_finalizer(r)) {
            return Err(format!(
                "packageinstance {} carries a Kix finalizer. Deleting its CRD would \
                 leave it Terminating for ever, and the retired API group with it.\n\
                 Clear the finalizers first:\n  \
                 kubectl get {} -A -o name | xargs -I{{}} kubectl patch {{}} --type=merge \
                 -p '{{\"metadata\":{{\"finalizers\":[]}}}}'\n\
                 Nothing has been written.",
                name_of(held).unwrap_or("<unnamed>"),
                crd_name(PACKAGE_INSTANCE, &from_group),
            ));
        }
    }

    report.finalizers_present = old.iter().any(has_legacy_finalizer);

    if dry_run {
        return Ok(report);
    }

    // Clear the operator's finalizers, wait, and look again.
    //
    // The finalizer on its own does not say whether an operator is running.
    // The operator adds it on every reconcile and removes it in one place
    // only, when the record is already being deleted. A Superseded record on
    // a cluster that ran the operator once carries one for ever. Refusing on
    // its presence would make this command unrunnable on exactly the
    // clusters that need it, and scaling the operator to 0, which is what
    // such a refusal would have to advise, would not clear a single one.
    //
    // Clearing them and reading back does answer the question, because only
    // a running operator puts one back. The probe is the first thing that
    // writes, so a refusal here leaves the cluster as it was found except
    // for finalizers that were going to be cleared anyway.
    if report.finalizers_present {
        strip_finalizers(ops, &from_group, &old).await?;
        ops.pause_for_operator().await;
        let after = ops.list_records(&from_group, ACTIVATION).await?;
        if let Some(held) = after.iter().find(|r| has_legacy_finalizer(r)) {
            return Err(format!(
                "the kix operator is running and watching {from_group}: the finalizer on \
                 activation {} came back after being cleared. Deleting the old CRDs while \
                 it watches them would make it delete every resource in the activation.\n\
                 Scale it to 0, then run this again. Nothing has been copied or deleted.",
                name_of(held).unwrap_or("<unnamed>")
            ));
        }
    }

    // The new CRDs first, so the copy has somewhere to land.
    for crd in crds {
        ops.apply_crd(crd).await?;
    }
    for record in [ACTIVATION, PACKAGE_INSTANCE] {
        ops.await_crd(&crd_name(record, keys::GROUP)).await?;
    }

    let existing: Vec<String> = ops
        .list_records(keys::GROUP, ACTIVATION)
        .await?
        .iter()
        .filter_map(name_of)
        .map(str::to_string)
        .collect();

    for record in &old {
        let Some(name) = name_of(record) else {
            continue;
        };
        let (body, status) = port_record(record);
        let already = existing.iter().any(|e| e == name);
        if already {
            report.already_present.push(name.to_string());
        } else {
            ops.create_record(keys::GROUP, ACTIVATION, &body).await?;
            report.copied.push(name.to_string());
        }
        // The status is a second call, because the CRD declares a status
        // subresource and a create drops it. Write it whether the record was
        // created now or by an earlier run that died in the gap: a record
        // with no phase is missing from `kix rollback --list` and
        // reads as Queued to the operator, which would supersede the real
        // Active activation and deploy an old build.
        if let Some(status) = status {
            ops.set_record_status(keys::GROUP, ACTIVATION, name, &status)
                .await?;
        }
    }

    // Nothing is deleted until every record is accounted for, by name AND by
    // phase. A name-only check would pass a record whose status write never
    // landed, and deleting the old CRDs then destroys the only copy of that
    // phase.
    let landed = ops.list_records(keys::GROUP, ACTIVATION).await?;
    for source in &old {
        let Some(name) = name_of(source) else {
            continue;
        };
        let Some(copy) = landed.iter().find(|r| name_of(r) == Some(name)) else {
            return Err(format!(
                "activation {name} did not appear under {}. Nothing was deleted; \
                 run this again once the apiserver is healthy.",
                keys::GROUP
            ));
        };
        if phase_of(copy) != phase_of(source) {
            return Err(format!(
                "activation {name} copied to {} without its phase ({} on the copy, \
                 {} on the original). Nothing was deleted; run this again.",
                keys::GROUP,
                phase_of(copy).unwrap_or("none"),
                phase_of(source).unwrap_or("none"),
            ));
        }
    }

    // Wait, then look once more before deleting anything.
    //
    // This is the one step that can destroy a cluster rather than a record.
    // Deleting the CRD marks every record for deletion; an operator holding
    // a finalizer on one then runs its own garbage collection and deletes
    // every resource in that activation: the workloads, the databases,
    // everything but the namespaces.
    //
    // Nothing is stripped here. After the probe above, a record carries a
    // finalizer only if something put it back, which means an operator
    // started while the copy was running. Stripping it would race the thing
    // that wrote it and then read the result of that race, so this refuses
    // instead. The wait is what makes the look mean anything: an operator
    // reconciles on the watch event, not instantly, and a check that reads
    // microseconds after the last write would find nothing however many
    // operators were running.
    ops.pause_for_operator().await;
    let before_delete = if old_crd_present {
        ops.list_records(&from_group, ACTIVATION).await?
    } else {
        Vec::new()
    };
    if let Some(held) = before_delete.iter().find(|r| has_legacy_finalizer(r)) {
        return Err(format!(
            "activation {} has a Kix finalizer again, so the kix operator started \
             while this was running and is watching {from_group}. Deleting the old \
             CRDs now would make it delete every resource in that activation.\n\
             Scale it to 0, then run this again. Nothing has been deleted; the \
             records already copied are skipped.",
            name_of(held).unwrap_or("<unnamed>")
        ));
    }

    for record in [PACKAGE_INSTANCE, ACTIVATION] {
        let name = crd_name(record, &from_group);
        if ops.crd_exists(&name).await? {
            ops.delete_crd(&name).await?;
            ops.await_crd_gone(&name).await?;
            report.crds_deleted.push(name);
        }
    }

    Ok(report)
}

/// The first retired group with an Activation CRD on this cluster.
async fn find_legacy_group(ops: &dyn MigrationOps) -> Result<Option<String>, String> {
    for domain in DOMAINS {
        // Both kinds, so a run that deleted one CRD and then failed leaves a
        // cluster the next run still recognises rather than one that reports
        // "nothing to do" with a retired CRD stranded on it for ever.
        for record in [ACTIVATION, PACKAGE_INSTANCE] {
            if ops.crd_exists(&crd_name(record, domain)).await? {
                return Ok(Some((*domain).to_string()));
            }
        }
    }
    Ok(None)
}

fn name_of(record: &Value) -> Option<&str> {
    record.pointer("/metadata/name").and_then(Value::as_str)
}

fn phase_of(record: &Value) -> Option<&str> {
    record.pointer("/status/phase").and_then(Value::as_str)
}

/// Does this record carry a Kix finalizer under a retired domain?
///
/// The operator puts one on every record it reconciles, so its presence is
/// how the migration knows an operator is watching the retired group.
/// Remove every retired-domain Kix finalizer from these records.
///
/// Idempotent: a record without one is patched to the same value it already
/// has.
async fn strip_finalizers(
    ops: &dyn MigrationOps,
    group: &str,
    records: &[Value],
) -> Result<(), String> {
    for record in records {
        let Some(name) = name_of(record) else {
            continue;
        };
        for finalizer in super::legacy_spellings(keys::OPERATOR_GC_FINALIZER) {
            ops.strip_finalizer(group, ACTIVATION, name, &finalizer)
                .await?;
        }
    }
    Ok(())
}

fn has_legacy_finalizer(record: &Value) -> bool {
    let Some(finalizers) = record
        .pointer("/metadata/finalizers")
        .and_then(Value::as_array)
    else {
        return false;
    };
    finalizers
        .iter()
        .filter_map(Value::as_str)
        .any(super::is_legacy_key)
}

/// One record under the current group, plus its status if it has one.
///
/// Name, spec, annotations and labels carry over; the annotations and labels
/// have their retired keys renamed. Server-set metadata does not carry over,
/// and neither do finalizers: the upgraded operator adds its own when it
/// first reconciles the record.
fn port_record(record: &Value) -> (Value, Option<Value>) {
    let mut metadata = json!({ "name": record.pointer("/metadata/name") });
    let mut upgraded = record.clone();
    super::upgrade_manifest(&mut upgraded);
    for field in ["annotations", "labels"] {
        if let Some(map) = upgraded.pointer(&format!("/metadata/{field}")) {
            metadata[field] = map.clone();
        }
    }
    let body = json!({
        "apiVersion": keys::API_VERSION,
        "kind": ACTIVATION.kind,
        "metadata": metadata,
        "spec": record.get("spec").cloned().unwrap_or_else(|| json!({})),
    });
    let status = record.get("status").cloned().filter(|s| !s.is_null());
    (body, status)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn crd_names_are_plural_dot_domain() {
        assert_eq!(
            crd_name(ACTIVATION, "example.com"),
            "activations.example.com"
        );
        assert_eq!(
            crd_name(PACKAGE_INSTANCE, "example.com"),
            "packageinstances.example.com"
        );
    }

    #[test]
    fn porting_keeps_name_spec_and_status_and_drops_finalizers() {
        let old = json!({
            "apiVersion": "legacy.example/v1alpha1",
            "kind": RECORD_KIND,
            "metadata": {
                "name": "stage2-abc",
                "finalizers": ["legacy.example/operator-gc"],
                "resourceVersion": "12345",
                "annotations": {"legacy.example/deployed-at": "2026-01-01T00:00:00Z"},
                "labels": {"legacy.example/cluster": "stage2"},
            },
            "spec": {"manifests": 3},
            "status": {"phase": "Active"},
        });
        let (body, status) = port_record(&old);
        assert_eq!(body["metadata"]["name"], json!("stage2-abc"));
        assert_eq!(body["spec"], json!({"manifests": 3}));
        assert_eq!(body["apiVersion"], json!(keys::API_VERSION));
        assert!(body["metadata"].get("finalizers").is_none());
        assert!(body["metadata"].get("resourceVersion").is_none());
        assert_eq!(status, Some(json!({"phase": "Active"})));
    }

    #[test]
    fn a_record_without_a_status_ports_without_one() {
        let (_, status) = port_record(&json!({"metadata": {"name": "x"}}));
        assert_eq!(status, None);
    }

    /// A scripted apiserver: it records the calls and answers from a
    /// scripted state, so each step can be checked on its own.
    #[derive(Default)]
    struct Fake {
        crds: Mutex<Vec<String>>,
        /// (group, record kind, object).
        records: Mutex<Vec<(String, &'static str, Value)>>,
        calls: Mutex<Vec<String>>,
        /// (group, finalizer): an operator that is running, so it re-adds
        /// its finalizer whenever the migration waits for it to reconcile.
        /// Keyed to the wait rather than to the strip, because no apiserver
        /// re-adds a finalizer inside the call that removes one: a guard
        /// that reads back without waiting would pass against a Fake that
        /// did, and fail against a real cluster.
        strip_hook: Mutex<Option<(String, String)>>,
        /// Record names whose status write is dropped on the floor.
        swallow_status: Mutex<Vec<String>>,
    }

    impl Fake {
        fn with_legacy(group: &str, records: Vec<Value>) -> Self {
            let f = Fake::default();
            f.crds.lock().unwrap().extend([
                crd_name(ACTIVATION, group),
                crd_name(PACKAGE_INSTANCE, group),
            ]);
            for r in records {
                f.records
                    .lock()
                    .unwrap()
                    .push((group.to_string(), ACTIVATION.kind, r));
            }
            f
        }
        fn calls(&self) -> Vec<String> {
            self.calls.lock().unwrap().clone()
        }

        /// Put a Kix finalizer back on every record in `group`, the way a
        /// running operator does on its next reconcile.
        fn operator_re_adds_finalizers(&self, group: &str, finalizer: &str) {
            for (g, k, v) in self.records.lock().unwrap().iter_mut() {
                if g == group && *k == ACTIVATION.kind {
                    v["metadata"]["finalizers"] = json!([finalizer]);
                }
            }
        }
    }

    #[async_trait]
    impl MigrationOps for Fake {
        async fn pause_for_operator(&self) {
            let hook = self.strip_hook.lock().unwrap().clone();
            if let Some((group, f)) = hook {
                self.operator_re_adds_finalizers(&group, &f);
            }
        }

        async fn crd_exists(&self, name: &str) -> Result<bool, String> {
            Ok(self.crds.lock().unwrap().iter().any(|c| c == name))
        }
        /// Errors when the CRD is not registered, as the apiserver does.
        /// Without this a test cannot tell a stranded half-deleted pair from
        /// a healthy one.
        async fn list_records(&self, group: &str, r: RecordKind) -> Result<Vec<Value>, String> {
            let crd = crd_name(r, group);
            if !self.crds.lock().unwrap().contains(&crd) {
                return Err(format!(
                    "the server could not find the requested resource: {crd}"
                ));
            }
            Ok(self
                .records
                .lock()
                .unwrap()
                .iter()
                .filter(|(g, k, _)| g == group && *k == r.kind)
                .map(|(_, _, v)| v.clone())
                .collect())
        }
        async fn apply_crd(&self, manifest: &Value) -> Result<(), String> {
            let name = manifest
                .pointer("/metadata/name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            self.calls.lock().unwrap().push(format!("apply_crd {name}"));
            self.crds.lock().unwrap().push(name);
            Ok(())
        }
        async fn await_crd(&self, _name: &str) -> Result<(), String> {
            Ok(())
        }
        async fn create_record(
            &self,
            group: &str,
            _r: RecordKind,
            manifest: &Value,
        ) -> Result<(), String> {
            let name = manifest
                .pointer("/metadata/name")
                .and_then(Value::as_str)
                .unwrap_or_default();
            self.calls.lock().unwrap().push(format!("create {name}"));
            self.records
                .lock()
                .unwrap()
                .push((group.to_string(), _r.kind, manifest.clone()));
            Ok(())
        }
        async fn set_record_status(
            &self,
            group: &str,
            _r: RecordKind,
            name: &str,
            status: &Value,
        ) -> Result<(), String> {
            self.calls.lock().unwrap().push(format!("status {name}"));
            if self
                .swallow_status
                .lock()
                .unwrap()
                .iter()
                .any(|n| n == name)
            {
                return Ok(());
            }
            let mut records = self.records.lock().unwrap();
            for (g, k, v) in records.iter_mut() {
                if g == group
                    && *k == _r.kind
                    && v.pointer("/metadata/name").and_then(Value::as_str) == Some(name)
                {
                    v["status"] = status.clone();
                }
            }
            Ok(())
        }
        async fn strip_finalizer(
            &self,
            _group: &str,
            _r: RecordKind,
            name: &str,
            finalizer: &str,
        ) -> Result<(), String> {
            self.calls
                .lock()
                .unwrap()
                .push(format!("strip {name} {finalizer}"));
            for (g, k, v) in self.records.lock().unwrap().iter_mut() {
                if g == _group
                    && *k == _r.kind
                    && v.pointer("/metadata/name").and_then(Value::as_str) == Some(name)
                    && let Some(list) = v
                        .pointer_mut("/metadata/finalizers")
                        .and_then(Value::as_array_mut)
                {
                    list.retain(|f| f.as_str() != Some(finalizer));
                }
            }
            Ok(())
        }
        async fn delete_crd(&self, name: &str) -> Result<(), String> {
            self.calls
                .lock()
                .unwrap()
                .push(format!("delete_crd {name}"));
            self.crds.lock().unwrap().retain(|c| c != name);
            Ok(())
        }
        async fn await_crd_gone(&self, _name: &str) -> Result<(), String> {
            Ok(())
        }
    }

    fn crd_manifests() -> Vec<Value> {
        [ACTIVATION, PACKAGE_INSTANCE]
            .iter()
            .map(|r| json!({"metadata": {"name": crd_name(*r, keys::GROUP)}}))
            .collect()
    }

    #[tokio::test]
    async fn a_cluster_with_no_retired_group_needs_nothing() {
        let fake = Fake::default();
        let report = run(&fake, &crd_manifests(), false).await.unwrap();
        assert!(!report.needed());
        assert!(fake.calls().is_empty(), "nothing should have been written");
    }

    #[tokio::test]
    async fn a_dry_run_lists_the_records_and_writes_nothing() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let fake = Fake::with_legacy(
            legacy,
            vec![json!({"metadata": {"name": "stage2-a"}, "status": {"phase": "Active"}})],
        );
        let report = run(&fake, &crd_manifests(), true).await.unwrap();
        assert!(report.dry_run);
        assert_eq!(report.activations, vec!["stage2-a".to_string()]);
        assert!(report.copied.is_empty());
        assert!(fake.calls().is_empty(), "a dry run writes nothing");
    }

    #[tokio::test]
    async fn a_deploy_in_flight_stops_the_migration() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let fake = Fake::with_legacy(
            legacy,
            vec![json!({"metadata": {"name": "stage2-a"}, "status": {"phase": PHASE_DEPLOYING}})],
        );
        let err = run(&fake, &crd_manifests(), false).await.unwrap_err();
        assert!(err.contains("still deploying"), "{err}");
        assert!(fake.calls().is_empty());
    }

    #[tokio::test]
    async fn records_are_copied_then_the_old_crds_go() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let fake = Fake::with_legacy(
            legacy,
            vec![
                json!({"metadata": {"name": "stage2-a"}, "spec": {"n": 1}, "status": {"phase": "Superseded"}}),
                json!({"metadata": {"name": "stage2-b"}, "spec": {"n": 2}, "status": {"phase": "Active"}}),
            ],
        );
        let report = run(&fake, &crd_manifests(), false).await.unwrap();
        assert_eq!(report.copied, vec!["stage2-a", "stage2-b"]);
        assert_eq!(report.crds_deleted.len(), 2);

        let calls = fake.calls();
        let last_create = calls.iter().rposition(|c| c.starts_with("create")).unwrap();
        let first_delete = calls
            .iter()
            .position(|c| c.starts_with("delete_crd"))
            .unwrap();
        assert!(
            last_create < first_delete,
            "every record must be copied before any CRD is deleted: {calls:?}"
        );
        assert!(
            !calls.iter().any(|c| c.starts_with("strip")),
            "records with no finalizer must not be patched at all: {calls:?}"
        );
    }

    /// A finalizer left behind by an operator that is no longer running must
    /// not stop the migration.
    ///
    /// The operator adds its finalizer on every reconcile and removes it in
    /// one place only, when the record is already being deleted. So every
    /// record on a cluster that ever ran the operator carries one for ever,
    /// and refusing on its presence would make this command unrunnable on
    /// exactly the clusters that need it. Worse, the only remedy such a
    /// refusal could advise, scaling the operator to 0, does not clear a
    /// single one.
    #[tokio::test]
    async fn a_finalizer_from_an_operator_that_is_not_running_does_not_stop_the_migration() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let finalizer = format!("{legacy}/operator-gc");
        let fake = Fake::with_legacy(
            legacy,
            vec![json!({
                "metadata": {"name": "stage2-a", "finalizers": [finalizer]},
                "status": {"phase": "Active"},
            })],
        );
        let report = run(&fake, &crd_manifests(), false).await.unwrap();
        assert!(report.finalizers_present);
        assert_eq!(report.copied, ["stage2-a"]);
        assert_eq!(report.crds_deleted.len(), 2);
    }

    /// The same finalizer, with something still putting it back. The probe
    /// clears it, waits and reads again; a finalizer that returns is the one
    /// signal that an operator is running. Nothing may be copied or deleted.
    #[tokio::test]
    async fn an_operator_that_re_adds_its_finalizer_stops_the_migration_before_any_copy() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let finalizer = format!("{legacy}/operator-gc");
        let fake = Fake::with_legacy(
            legacy,
            vec![json!({
                "metadata": {"name": "stage2-a", "finalizers": [finalizer]},
                "status": {"phase": "Active"},
            })],
        );
        fake.strip_hook
            .lock()
            .unwrap()
            .replace((legacy.to_string(), finalizer));
        let err = run(&fake, &crd_manifests(), false).await.unwrap_err();
        assert!(err.contains("Scale it to 0"), "{err}");
        assert!(
            !fake
                .calls()
                .iter()
                .any(|c| c.starts_with("apply_crd") || c.starts_with("create")),
            "nothing may be copied: {:?}",
            fake.calls()
        );
    }

    /// An operator started after the probe had already passed, so the only
    /// thing standing between it and a destroyed cluster is the wait and the
    /// look immediately before the delete. Nothing may be deleted.
    #[tokio::test]
    async fn an_operator_that_starts_during_the_copy_stops_the_delete() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let fake = Fake::with_legacy(
            legacy,
            vec![json!({"metadata": {"name": "stage2-a"}, "status": {"phase": "Active"}})],
        );
        fake.strip_hook
            .lock()
            .unwrap()
            .replace((legacy.to_string(), format!("{legacy}/operator-gc")));
        let err = run(&fake, &crd_manifests(), false).await.unwrap_err();
        assert!(err.contains("Scale it to 0"), "{err}");
        assert!(
            !fake.calls().iter().any(|c| c.starts_with("delete_crd")),
            "no CRD may be deleted: {:?}",
            fake.calls()
        );
    }

    /// A run that deleted one of the two retired CRDs and then died.
    ///
    /// `find_legacy_group` accepts either CRD, so the cluster is still
    /// recognised. Listing the kind whose CRD is already gone would 404 and
    /// fail the whole command, dry run included, leaving the other one
    /// stranded with no way to clear it.
    #[tokio::test]
    async fn a_half_deleted_crd_pair_is_finished_rather_than_erroring() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let fake = Fake::default();
        // Only the PackageInstance CRD is left.
        fake.crds
            .lock()
            .unwrap()
            .push(crd_name(PACKAGE_INSTANCE, legacy));

        let plan = run(&fake, &crd_manifests(), true).await.unwrap();
        assert_eq!(plan.from_group.as_deref(), Some(*legacy));
        assert!(plan.activations.is_empty());

        let report = run(&fake, &crd_manifests(), false).await.unwrap();
        assert!(report.copied.is_empty());
        assert_eq!(report.crds_deleted, [crd_name(PACKAGE_INSTANCE, legacy)]);
    }

    /// A copy whose status write never landed must not let the originals be
    /// deleted: the phase would be lost, and a record with no phase reads as
    /// Queued to the operator, which would deploy an old build.
    #[tokio::test]
    async fn a_copy_without_its_phase_stops_the_delete() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let fake = Fake::with_legacy(
            legacy,
            vec![json!({"metadata": {"name": "stage2-a"}, "status": {"phase": "Active"}})],
        );
        fake.records.lock().unwrap().push((
            keys::GROUP.to_string(),
            ACTIVATION.kind,
            json!({"metadata": {"name": "stage2-a"}}),
        ));
        fake.swallow_status
            .lock()
            .unwrap()
            .push("stage2-a".to_string());
        let err = run(&fake, &crd_manifests(), false).await.unwrap_err();
        assert!(err.contains("without its phase"), "{err}");
        assert!(!fake.calls().iter().any(|c| c.starts_with("delete_crd")));
    }

    #[tokio::test]
    async fn a_second_run_repairs_a_status_that_never_landed() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let fake = Fake::with_legacy(
            legacy,
            vec![json!({"metadata": {"name": "stage2-a"}, "status": {"phase": "Active"}})],
        );
        // A previous run created the record and died before writing status.
        fake.records.lock().unwrap().push((
            keys::GROUP.to_string(),
            ACTIVATION.kind,
            json!({"metadata": {"name": "stage2-a"}}),
        ));
        let report = run(&fake, &crd_manifests(), false).await.unwrap();
        assert_eq!(report.already_present, vec!["stage2-a".to_string()]);
        assert!(
            fake.calls().iter().any(|c| c == "status stage2-a"),
            "the status must be re-driven for a record an earlier run left without one: {:?}",
            fake.calls()
        );
        assert_eq!(report.crds_deleted.len(), 2);
    }

    #[tokio::test]
    async fn a_second_run_skips_what_it_already_copied() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let fake = Fake::with_legacy(
            legacy,
            vec![json!({"metadata": {"name": "stage2-a"}, "status": {"phase": "Active"}})],
        );
        fake.records.lock().unwrap().push((
            keys::GROUP.to_string(),
            ACTIVATION.kind,
            json!({"metadata": {"name": "stage2-a"}}),
        ));
        let report = run(&fake, &crd_manifests(), false).await.unwrap();
        assert_eq!(report.already_present, vec!["stage2-a".to_string()]);
        assert!(report.copied.is_empty());
        assert_eq!(report.crds_deleted.len(), 2);
    }
}
