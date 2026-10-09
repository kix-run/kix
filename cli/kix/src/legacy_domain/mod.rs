//! Everything that exists only because Kix once stamped a domain it has
//! since retired.
//!
//! Kix used `kix.dev` for the prefix of every annotation and label it
//! stamps, and for the API group of its two CRDs. We do not own that name.
//! `kix.run`, which we do own, replaced it. Clusters deployed before that
//! still carry the old keys and, until they are migrated, the old CRDs.
//!
//! # The shape of the compatibility layer
//!
//! This module is the whole of it. The rest of the codebase reaches it
//! through four one-line hooks:
//!
//! 1. [`fallback`], from `keys::get` and `keys::get_meta`. A live object
//!    stamped by an older Kix still parses.
//! 2. [`upgrade_manifest`], from stamping a loaded build and from the live
//!    reconstruction in `kix deploy`. A build loaded from an old activation,
//!    or a set of live objects projected back to manifests, is brought to
//!    the current domain before the planner ever sees it.
//! 3. [`bookkeeping_null_outs`], from the two merge patches in
//!    `cluster::apply`. Server-side apply drops the build-time keys on its
//!    own because the `kix` field manager owns them; these two are written
//!    by patch and would otherwise stay on the object forever.
//! 4. [`check_discovery`] and [`check_build`], the gate. Every command that
//!    reads Kix records opens them through
//!    [`crate::cluster::activation::Records::open`], which refuses a cluster
//!    that has not been migrated and names the command to run. `Build`
//!    checks each build it loads, and the commands that install a build's
//!    CRDs refuse a stale one
//!    ([`crate::build_source::Build::installable`]).
//!
//! Plus the migration itself, [`migrate::run`], behind `kix migrate domain`.
//!
//! # Deleting it
//!
//! Set [`DOMAINS`] to `&[]` and the layer is inert. Removing it for real is
//! a checklist in `v2_discussions/archive/137_kix_run_domain_migration.md`: delete
//! this directory and `kix-cli`'s `migrate` command, remove the four hooks,
//! drop `legacyDomains` from `kix/lib/core/annotations.nix`, and shrink the
//! allowlist in `keys`'s `no_other_file_spells_a_kix_domain` test.

use kube::discovery::{ApiResource, Scope};
use serde_json::{Map, Value};

use crate::manifest::keys;

pub mod kube_ops;
pub mod migrate;

pub use kube_ops::KubeMigrationOps;

/// Domains Kix has stamped and retired, newest first.
///
/// `kix.dev` is here because Kix stamped it until 2026-09 and we do not own
/// it. Emptying this list makes the whole layer inert: no fallback lookup,
/// no manifest upgrade, no null-outs, and a gate that never fires. The Nix
/// half is `legacyDomains` in `kix/lib/core/annotations.nix`.
pub const DOMAINS: &[&str] = &["kix.dev"];

/// Does `key` sit under `domain`, as in `kix.dev/package`?
fn under(key: &str, domain: &str) -> bool {
    key.len() > domain.len() && key.starts_with(domain) && key.as_bytes()[domain.len()] == b'/'
}

/// Is this a Kix key under a retired domain?
pub fn is_legacy_key(key: &str) -> bool {
    is_key_under_any(key, DOMAINS)
}

/// Is this a Kix key under any of `domains`? Parameterised so the tests can
/// drive both an empty retired list and a populated one.
fn is_key_under_any(key: &str, domains: &[&str]) -> bool {
    domains.iter().any(|d| under(key, d))
}

/// The same key under each retired domain, newest first.
///
/// `key` is a current-domain constant. Returns nothing for a key that is
/// not Kix's own.
pub fn legacy_spellings(key: &str) -> Vec<String> {
    let Some(name) = key.strip_prefix(keys::PREFIX) else {
        return Vec::new();
    };
    DOMAINS.iter().map(|d| format!("{d}/{name}")).collect()
}

/// Is this live object still carrying the identity stamp a pre-move Kix
/// wrote? `has` answers whether one exact annotation key is present.
///
/// True when the retired spelling is there and the current one is not. That
/// is the window between `kix migrate domain` and the first deploy after it:
/// the records have moved, so the gate in [`check_discovery`] passes, but
/// every object on the cluster still carries the annotations the old build
/// wrote. Nothing reconciles that until a deploy re-applies them.
///
/// It matters because an identity hash covers the manifest that produced it,
/// and the move changed every manifest. So in this window a live hash never
/// equals the hash of the same resource in a fresh build. Anything that
/// treats "hash not in the expected set" as "this resource is garbage" would
/// condemn the entire cluster.
pub fn stamped_before_move<F>(has: F) -> bool
where
    F: Fn(&str) -> bool,
{
    !has(keys::IDENTITY_HASH) && legacy_spellings(keys::IDENTITY_HASH).iter().any(|k| has(k))
}

/// Every retired Kix key on an object Kix has just applied.
///
/// Server-side apply drops these on its own, but only where the `kix` field
/// manager owns them. An object whose `managedFields` are empty, which is
/// what client-side `kubectl apply` leaves behind, has no owner for them: the
/// apply adds the current spelling and the retired one stays beside it. Four
/// coredns objects on stage1 were in exactly that state after the move.
///
/// Only ever called after a successful apply, which is what makes clearing
/// them right rather than merely tidy. The apply wrote the object's complete
/// current key set from the build, so a retired key is by definition not
/// part of what the object should now carry. Left alone it is worse than
/// untidy: [`fallback`] reads a retired key whenever the current one is
/// absent, so a stale value from an older build generation would be returned
/// as though it were true.
///
/// The skipped path must never call this. There the resource was not
/// re-applied and its retired keys are the only ones it has.
pub fn retired_keys(annotations: &std::collections::BTreeMap<String, String>) -> Vec<String> {
    annotations
        .keys()
        .filter(|k| is_legacy_key(k))
        .cloned()
        .collect()
}

/// Look `key` up under each retired domain in turn.
///
/// The hook in `keys::get` and `keys::get_meta`. `lookup` reads one key out
/// of whatever map the caller holds.
pub fn fallback<'a, F>(key: &str, lookup: F) -> Option<&'a str>
where
    F: Fn(&str) -> Option<&'a str>,
{
    legacy_spellings(key).into_iter().find_map(|k| lookup(&k))
}

/// Bring every Kix annotation and label on a manifest to the current domain.
///
/// The hook in the store-graph loader and in `kix deploy`'s live
/// reconstruction. A manifest that has been through this carries no retired
/// key, so the planner, the differ and the stamper all see one domain.
///
/// A key already present under the current domain wins: it is what the
/// running Kix wrote, and the retired one is what it replaced.
pub fn upgrade_manifest(manifest: &mut Value) {
    upgrade_manifest_from(manifest, DOMAINS);
}

/// [`upgrade_manifest`] against a given retired list. With an empty list it
/// is a no-op, which is what makes removing the layer safe.
fn upgrade_manifest_from(manifest: &mut Value, domains: &[&str]) {
    for field in ["annotations", "labels"] {
        let pointer = format!("/metadata/{field}");
        if let Some(map) = manifest
            .pointer_mut(&pointer)
            .and_then(Value::as_object_mut)
        {
            upgrade_map(map, domains);
        }
    }
    upgrade_api_version(manifest, domains);
    upgrade_own_crd(manifest, domains);
}

/// Move Kix's own CustomResourceDefinition to the current group.
///
/// A CRD carries its group in `metadata.name` and `spec.group`, not in its
/// `apiVersion`, so [`upgrade_api_version`] does not reach it. Every build
/// Kix has ever made contains these two CRDs, so without this the old side
/// of a deploy diff, and every `kix rollback` target, names
/// `activations.<retired>`. That resource does not exist after a migration,
/// so it is computed as an orphan: the plan shows two deletions that make no
/// sense, and under `--prune` two 404s fail the deploy and finalize the
/// activation Degraded when nothing actually failed.
///
/// Only Kix's own CRDs move. Another package's CRD under a retired Kix
/// domain would be someone else's resource and is left alone.
fn upgrade_own_crd(manifest: &mut Value, domains: &[&str]) {
    if manifest.get("kind").and_then(Value::as_str) != Some("CustomResourceDefinition") {
        return;
    }
    let Some(group) = manifest.pointer("/spec/group").and_then(Value::as_str) else {
        return;
    };
    if !domains.contains(&group) {
        return;
    }
    let Some(plural) = manifest
        .pointer("/spec/names/plural")
        .and_then(Value::as_str)
        .map(str::to_string)
    else {
        return;
    };
    // Kix does not own the retired domain, so a CRD under it is not
    // necessarily Kix's. Only these two kinds move; anything else in that
    // group belongs to whoever registered it and is left exactly as found.
    let ours = [migrate::ACTIVATION.plural, migrate::PACKAGE_INSTANCE.plural];
    if !ours.contains(&plural.as_str()) {
        return;
    }
    manifest["spec"]["group"] = Value::String(keys::GROUP.to_string());
    manifest["metadata"]["name"] = Value::String(format!("{plural}.{}", keys::GROUP));
}

/// Move one of Kix's own records to the current API group.
///
/// Without this, `kix rollback` to an activation from before the move would
/// apply an Activation whose `apiVersion` still names the retired group,
/// which puts the retired CRD back on a migrated cluster. The version is
/// kept: only the group moves.
fn upgrade_api_version(manifest: &mut Value, domains: &[&str]) {
    // Only Kix's own two kinds. Kix does not own the retired domain, so
    // another project's custom resource could legitimately live in that
    // group, and renaming its apiVersion would misreport it as something it
    // is not. The same reasoning as `upgrade_own_crd`.
    let kind = manifest.get("kind").and_then(Value::as_str);
    if !matches!(
        kind,
        Some(crate::manifest::lifecycle::RECORD_KIND)
            | Some(crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND)
    ) {
        return;
    }
    let Some(api_version) = manifest.get("apiVersion").and_then(Value::as_str) else {
        return;
    };
    let Some((group, version)) = api_version.split_once('/') else {
        return;
    };
    if !domains.contains(&group) {
        return;
    }
    manifest["apiVersion"] = Value::String(format!("{}/{version}", keys::GROUP));
}

/// Rename the retired keys in one metadata map.
fn upgrade_map(map: &mut Map<String, Value>, domains: &[&str]) {
    let legacy: Vec<String> = map
        .keys()
        .filter(|k| is_key_under_any(k, domains))
        .cloned()
        .collect();
    for old in legacy {
        let Some(value) = map.remove(&old) else {
            continue;
        };
        let Some((_, name)) = old.split_once('/') else {
            continue;
        };
        let new = format!("{}{name}", keys::PREFIX);
        map.entry(new).or_insert(value);
    }
}

/// The retired spellings of the keys this patch is about to write.
///
/// The hook in `cluster::apply`. Server-side apply drops the build-time keys
/// on its own, because the `kix` field manager owns them and the new
/// manifest does not have them. `activations` and `applied-hash` are written
/// by merge patch and are owned by nobody, so they have to be removed by
/// name or they outlive the move.
///
/// `writing` is what the patch actually sets. Only those keys are cleared.
/// Clearing a retired key the patch is not replacing would leave the object
/// with no value under either domain: on the skipped path, where nothing was
/// applied and `applied-hash` is not rewritten, that would blind
/// drift detection on the resource for good, because an unchanged resource is
/// never applied again.
pub fn bookkeeping_null_outs(writing: &[&str]) -> Vec<String> {
    writing.iter().flat_map(|k| legacy_spellings(k)).collect()
}

/// The cluster is not ready for this Kix.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum LegacyDomainError {
    #[error(
        "this cluster's Kix records use the retired {group} API group.\n\
         Run once:  kix migrate domain <cluster>\n\
         Then retry. `kix migrate domain --help` says what it does."
    )]
    NotMigrated { group: String },

    #[error(
        "this cluster has Kix records under both {legacy} and {current}. A \
         migration was interrupted.\n\
         Run again:  kix migrate domain <cluster>\n\
         It skips what it already copied."
    )]
    BothGroups { legacy: String, current: String },

    #[error(
        "this build renders Kix's own records under the retired {group} API \
         group, which would put the old CRDs back on the cluster.\n\
         Update the kixpkgs pin to a revision at or after the {current} move."
    )]
    StalePin { group: String, current: String },
}

/// Does discovery show Kix records under a retired group?
///
/// The gate. [`crate::cluster::activation::Records::open`] runs it, so every
/// command that reads or writes a record is covered. A command that only
/// reads objects calls it itself where an unmigrated cluster would mislead
/// it, as `kix diff` and `kix plan` do.
pub fn check_discovery(discovery: &[(ApiResource, Scope)]) -> Result<(), LegacyDomainError> {
    let groups: Vec<&str> = discovery
        .iter()
        .filter(|(ar, _)| crate::manifest::lifecycle::is_record_kind(&ar.kind))
        .map(|(ar, _)| ar.group.as_str())
        .collect();
    check_cluster(&groups)
}

/// [`check_discovery`] on the API groups that serve a record kind.
fn check_cluster(groups_in_discovery: &[&str]) -> Result<(), LegacyDomainError> {
    let legacy = DOMAINS
        .iter()
        .find(|d| groups_in_discovery.contains(&d.to_string().as_str()));
    let Some(legacy) = legacy else {
        return Ok(());
    };
    if groups_in_discovery.contains(&keys::GROUP) {
        return Err(LegacyDomainError::BothGroups {
            legacy: (*legacy).to_string(),
            current: keys::GROUP.to_string(),
        });
    }
    Err(LegacyDomainError::NotMigrated {
        group: (*legacy).to_string(),
    })
}

/// Does this build render Kix's own records under a retired group?
///
/// Catches a kixpkgs pin from before the move. Without it, deploying such a
/// build would re-create the retired CRDs on a migrated cluster and leave
/// two groups live, which the CLI cannot tell apart.
///
/// It must see the build as loaded: stamping upgrades a build to the current
/// domain, after which a stale pin looks exactly like a current one. So
/// [`crate::build_source::Build`] runs it as it loads a build, before
/// stamping, and keeps the verdict.
pub(crate) fn check_build<'a>(
    manifests: impl IntoIterator<Item = &'a Value>,
) -> Result<(), LegacyDomainError> {
    for m in manifests {
        // A CustomResourceDefinition for Kix's own kinds under a retired
        // group. This is the one that survives `upgrade_manifest`, because
        // the group lives in the CRD's spec and its name, not in the
        // apiVersion of the CRD object.
        if m.get("kind").and_then(Value::as_str) == Some("CustomResourceDefinition")
            && let Some(group) = m.pointer("/spec/group").and_then(Value::as_str)
            && DOMAINS.contains(&group)
            // Kix's own two kinds only. Kix does not own the retired domain,
            // so a third party's CRD can sit in that group legitimately, and
            // calling it a stale kixpkgs pin would be the wrong diagnosis.
            // The same restraint `upgrade_own_crd` shows.
            && m.pointer("/spec/names/plural")
                .and_then(Value::as_str)
                .is_some_and(|p| {
                    [migrate::ACTIVATION.plural, migrate::PACKAGE_INSTANCE.plural].contains(&p)
                })
        {
            return Err(LegacyDomainError::StalePin {
                group: group.to_string(),
                current: keys::GROUP.to_string(),
            });
        }
        // A record whose own apiVersion names a retired group, for a caller
        // that checks before the manifests are upgraded.
        if let Some((group, _)) = m
            .get("apiVersion")
            .and_then(Value::as_str)
            .and_then(|v| v.split_once('/'))
            && DOMAINS.contains(&group)
            && matches!(
                m.get("kind").and_then(Value::as_str),
                Some(crate::manifest::lifecycle::RECORD_KIND)
                    | Some(crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND)
            )
        {
            return Err(LegacyDomainError::StalePin {
                group: group.to_string(),
                current: keys::GROUP.to_string(),
            });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// With no retired domain every hook is a no-op. This is the property
    /// that makes deleting the layer safe, so it is tested directly rather
    /// than inferred from the current list.
    #[test]
    fn an_empty_retired_list_changes_nothing() {
        let mut m = json!({
            "apiVersion": "old.example/v1alpha1",
            "metadata": {"annotations": {"old.example/package": "a"}},
        });
        let before = m.clone();
        upgrade_manifest_from(&mut m, &[]);
        assert_eq!(m, before);
        assert!(!is_key_under_any("old.example/package", &[]));
        assert_eq!(check_cluster(&["old.example", keys::GROUP]), Ok(()));
    }

    #[test]
    fn a_key_must_be_followed_by_a_slash_to_be_under_a_domain() {
        assert!(under("kix.example/package", "kix.example"));
        assert!(!under("kix.example", "kix.example"));
        assert!(!under("kix.exampleish/package", "kix.example"));
    }

    #[test]
    fn every_retired_spelling_of_a_key_is_offered() {
        let spellings = legacy_spellings(keys::IDENTITY_HASH);
        assert_eq!(spellings.len(), DOMAINS.len());
        for (spelling, domain) in spellings.iter().zip(DOMAINS) {
            assert_eq!(spelling, &format!("{domain}/identity-hash"));
        }
        assert!(legacy_spellings("helm.sh/hook").is_empty());
    }

    #[test]
    fn upgrading_renames_annotations_and_labels() {
        let mut m = json!({
            "metadata": {
                "annotations": {"old.example/package": "vm-agent", "helm.sh/hook": "x"},
                "labels": {"old.example/cluster": "stage2"},
            },
        });
        upgrade_manifest_from(&mut m, &["old.example"]);
        assert_eq!(
            m["metadata"]["annotations"][keys::PACKAGE],
            json!("vm-agent")
        );
        assert_eq!(m["metadata"]["annotations"]["helm.sh/hook"], json!("x"));
        assert_eq!(m["metadata"]["labels"][keys::CLUSTER_LABEL], json!("stage2"));
        assert!(
            m["metadata"]["annotations"]
                .get("old.example/package")
                .is_none()
        );
    }

    /// The running Kix wrote the current key; the retired one is what it
    /// replaced, so it must not overwrite.
    #[test]
    fn the_current_key_wins_over_a_retired_one() {
        let mut m = json!({
            "metadata": {"annotations": {
                keys::PACKAGE: "current",
                "old.example/package": "retired",
            }},
        });
        upgrade_manifest_from(&mut m, &["old.example"]);
        assert_eq!(
            m["metadata"]["annotations"][keys::PACKAGE],
            json!("current")
        );
    }

    /// Without this a rollback to a pre-move activation would apply a record
    /// under the retired group and put its CRD back.
    #[test]
    fn upgrading_moves_a_record_to_the_current_group() {
        let mut m = json!({"apiVersion": "old.example/v1alpha1", "kind": "Activation"});
        upgrade_manifest_from(&mut m, &["old.example"]);
        assert_eq!(m["apiVersion"], json!(keys::API_VERSION));

        // A foreign resource is left alone.
        let mut other = json!({"apiVersion": "apps/v1", "kind": "Deployment"});
        let before = other.clone();
        upgrade_manifest_from(&mut other, &["old.example"]);
        assert_eq!(other, before);
    }

    #[test]
    fn the_bookkeeping_null_outs_cover_both_patch_written_keys() {
        let both = bookkeeping_null_outs(&[keys::ACTIVATIONS, keys::APPLIED_HASH]);
        assert_eq!(both.len(), DOMAINS.len() * 2);
        for domain in DOMAINS {
            assert!(both.contains(&format!("{domain}/activations")));
            assert!(both.contains(&format!("{domain}/applied-hash")));
        }

        // The skipped path writes only `activations`. Clearing the retired
        // `applied-hash` there would leave the object with no stamp under
        // either domain, and an unchanged resource is never applied again,
        // so drift detection would be off for it for good.
        let one = bookkeeping_null_outs(&[keys::ACTIVATIONS]);
        assert_eq!(one.len(), DOMAINS.len());
        for domain in DOMAINS {
            assert!(one.contains(&format!("{domain}/activations")));
            assert!(!one.contains(&format!("{domain}/applied-hash")));
        }
        assert!(bookkeeping_null_outs(&[]).is_empty());
    }

    #[test]
    fn a_cluster_still_on_a_retired_group_is_refused() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        assert_eq!(
            check_cluster(&[legacy]),
            Err(LegacyDomainError::NotMigrated {
                group: (*legacy).to_string()
            })
        );
        assert_eq!(check_cluster(&[keys::GROUP]), Ok(()));
        assert_eq!(check_cluster(&[]), Ok(()));
    }

    /// An interrupted migration leaves both groups live, which the CLI
    /// cannot tell apart, so it is its own message.
    #[test]
    fn a_cluster_with_both_groups_is_refused_differently() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        assert_eq!(
            check_cluster(&[legacy, keys::GROUP]),
            Err(LegacyDomainError::BothGroups {
                legacy: (*legacy).to_string(),
                current: keys::GROUP.to_string(),
            })
        );
    }

    #[test]
    fn a_build_that_renders_the_retired_crds_is_refused() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let crd = json!({
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {"name": format!("activations.{legacy}")},
            "spec": {"group": legacy, "names": {"plural": "activations"}},
        });
        assert!(matches!(
            check_build(&[crd]),
            Err(LegacyDomainError::StalePin { .. })
        ));
    }

    /// A stale pin is a build that renders KIX's own CRDs under the retired
    /// group. Kix does not own that domain, so another project's CRD living
    /// in it is not evidence of anything about the pin, and refusing the
    /// build would be the wrong diagnosis for a cluster that is fine.
    #[test]
    fn a_third_party_crd_in_the_retired_group_is_not_a_stale_pin() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let crd = json!({
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {"name": format!("widgets.{legacy}")},
            "spec": {"group": legacy, "names": {"plural": "widgets"}},
        });
        assert_eq!(check_build(&[crd]), Ok(()));
    }

    /// Likewise for a custom resource: only Kix's own two kinds say
    /// anything about the pin.
    #[test]
    fn a_third_party_record_in_the_retired_group_is_not_a_stale_pin() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let cr = json!({"apiVersion": format!("{legacy}/v1"), "kind": "Widget"});
        assert_eq!(check_build(&[cr]), Ok(()));
    }

    #[test]
    fn a_record_under_the_retired_group_is_refused() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let record = json!({"apiVersion": format!("{legacy}/v1alpha1"), "kind": "Activation"});
        assert!(matches!(
            check_build(&[record]),
            Err(LegacyDomainError::StalePin { .. })
        ));
    }

    /// A build from before the move names Kix's own CRDs under the retired
    /// group. The old side of a deploy diff and every rollback target are
    /// such builds, so if this did not move them the deploy would compute two
    /// phantom orphans, print two nonsense deletions, and under `--prune`
    /// fail on two 404s and finalize the activation Degraded.
    #[test]
    fn upgrading_moves_kixs_own_crds() {
        let mut crd = json!({
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {"name": "activations.old.example"},
            "spec": {"group": "old.example", "names": {"plural": "activations"}},
        });
        upgrade_manifest_from(&mut crd, &["old.example"]);
        assert_eq!(
            crd["metadata"]["name"],
            json!(format!("activations.{}", keys::GROUP))
        );
        assert_eq!(crd["spec"]["group"], json!(keys::GROUP));
    }

    /// Someone else's CRD that happens to sit under a retired Kix domain is
    /// their resource, not ours.
    #[test]
    fn upgrading_leaves_a_foreign_crd_alone() {
        let mut crd = json!({
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {"name": "widgets.acme.example"},
            "spec": {"group": "acme.example", "names": {"plural": "widgets"}},
        });
        let before = crd.clone();
        upgrade_manifest_from(&mut crd, &["old.example"]);
        assert_eq!(crd, before);
    }

    /// The claim in `upgrade_own_crd` is that only Kix's own two kinds move.
    /// Kix does not own the retired domain, so a CRD sitting in that group
    /// may well be someone else's. Renaming it into `kix.run` would apply a
    /// third party's resource under a name they never chose.
    ///
    /// The earlier version of this test used a group that was not retired at
    /// all, so it passed without exercising the guard.
    #[test]
    fn a_third_party_crd_in_a_retired_group_is_left_alone() {
        let retired = "old.example";
        let mut crd = json!({
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {"name": format!("widgets.{retired}")},
            "spec": {"group": retired, "names": {"plural": "widgets"}},
        });
        let before = crd.clone();
        upgrade_manifest_from(&mut crd, &[retired]);
        assert_eq!(crd, before, "only activations and packageinstances move");
    }

    /// The window between `kix migrate domain` and the first deploy after
    /// it: the records have moved, so the discovery gate passes, but every
    /// object still carries the annotations the pre-move build wrote.
    #[test]
    fn an_object_stamped_before_the_move_is_recognised() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let old_key = format!("{legacy}/identity-hash");
        assert!(stamped_before_move(|k| k == old_key));
        // Once a deploy has re-stamped it, it is current even though the
        // retired key may linger until the merge patch clears it.
        assert!(!stamped_before_move(
            |k| k == keys::IDENTITY_HASH || k == old_key
        ));
        assert!(!stamped_before_move(|k| k == keys::IDENTITY_HASH));
        // An object Kix never stamped is not this case.
        assert!(!stamped_before_move(|_| false));
    }

    /// Server-side apply drops a retired key only where the `kix` field
    /// manager owns it. On an object written by client-side `kubectl apply`
    /// the `managedFields` are empty, so it owns nothing, and the retired
    /// key sits beside the current one for ever.
    #[test]
    fn every_retired_key_on_an_applied_object_is_cleared() {
        let Some(legacy) = DOMAINS.first() else {
            return;
        };
        let mut anns = std::collections::BTreeMap::new();
        anns.insert(format!("{legacy}/content-hash"), "old".to_string());
        anns.insert(keys::CONTENT_HASH.to_string(), "new".to_string());
        // No current counterpart. Still residue: the apply that just ran
        // wrote every key this object should carry, and this was not one of
        // them. Keeping it would leave `fallback` returning a value from an
        // older build generation as though it were current.
        anns.insert(format!("{legacy}/depends-on"), "stale".to_string());
        // Not Kix's, and not ours to remove.
        anns.insert("helm.sh/hook".to_string(), "x".to_string());

        let mut got = retired_keys(&anns);
        got.sort();
        assert_eq!(
            got,
            vec![
                format!("{legacy}/content-hash"),
                format!("{legacy}/depends-on")
            ]
        );
    }

    #[test]
    fn a_current_build_passes() {
        assert_eq!(
            check_build(&[
                json!({}),
                json!({"apiVersion": "v1", "kind": "ConfigMap"}),
                json!({"apiVersion": keys::API_VERSION, "kind": "Activation"}),
                json!({
                    "apiVersion": "apiextensions.k8s.io/v1",
                    "kind": "CustomResourceDefinition",
                    "spec": {"group": keys::GROUP},
                }),
            ]),
            Ok(())
        );
    }
}
