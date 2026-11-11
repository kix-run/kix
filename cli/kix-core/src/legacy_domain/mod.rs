//! Compatibility layer for Kix's retired API domain.
//!
//! Kix previously used `kix.dev` as the prefix for its annotations and labels
//! and as the API group for its two CRDs. It now uses `kix.run`. Clusters
//! deployed before the switch still carry the legacy keys and, until they are
//! migrated, the legacy CRDs.
//!
//! # Compatibility hooks
//!
//! The rest of the codebase reaches this module through four hooks:
//!
//! 1. `fallback`, called from `keys::get` and `keys::get_meta`, so live
//!    objects stamped by an older Kix still parse.
//! 2. [`upgrade_manifest`], called when stamping a loaded build and when
//!    reconstructing live state in `kix deploy`. Builds loaded from an old
//!    activation and live objects projected back to manifests are upgraded to
//!    the current domain before the planner sees them.
//! 3. `bookkeeping_null_outs`, called from the two merge patches in
//!    `cluster::apply`. Server-side apply drops build-time keys automatically
//!    because the `kix` field manager owns them, whereas patch-written keys
//!    must be explicitly nulled out.
//! 4. `check_discovery` (in `kix-lib`) and `check_build`. Every command that
//!    reads Kix records opens them through `kix-lib`'s `Records::open`,
//!    which rejects an unmigrated cluster and prints the migration command.
//!    `Build` checks each loaded build, and commands that install CRDs reject
//!    builds that still use the retired group
//!    ([`crate::build_source::Build::installable`]).
//!
//! `kix-lib`'s `legacy_domain::migrate::run` implements the migration behind
//! `kix migrate domain`.
//!
//! # Removing this layer
//!
//! Setting [`DOMAINS`] to `&[]` makes the entire layer a no-op. To remove it
//! completely, delete this directory and `kix-cli`'s `migrate` command, remove
//! the four hooks, drop `legacyDomains` from `kix/lib/core/annotations.nix`,
//! and shrink the allowlist in `keys`'s `no_other_file_spells_a_kix_domain`
//! test.

use serde_json::{Map, Value};

use crate::manifest::keys;

/// The plural resource name of Kix's deploy records (`Activation`).
pub const ACTIVATION_PLURAL: &str = "activations";
/// The plural resource name of Kix's package markers (`PackageInstance`).
pub const PACKAGE_INSTANCE_PLURAL: &str = "packageinstances";

/// Domains Kix has stamped and retired, newest first.
///
/// `kix.dev` is here because Kix stamped it until 2026-09 and we do not own
/// it. Emptying this list makes the whole layer inert: no fallback lookup,
/// no manifest upgrade, no null-outs, and a gate that never fires. The Nix
/// half is `legacyDomains` in `kix/lib/core/annotations.nix`.
pub const DOMAINS: &[&str] = &["kix.dev"];

/// Return whether `key` sits under `domain` (for example, `kix.dev/package`).
fn under(key: &str, domain: &str) -> bool {
    key.len() > domain.len() && key.starts_with(domain) && key.as_bytes()[domain.len()] == b'/'
}

/// Return whether `key` is a Kix key under a retired domain.
pub fn is_legacy_key(key: &str) -> bool {
    is_key_under_any(key, DOMAINS)
}

/// Return whether `key` sits under any domain in `domains`. Parameterized so
/// tests can exercise both an empty and a populated retired-domain list.
fn is_key_under_any(key: &str, domains: &[&str]) -> bool {
    domains.iter().any(|d| under(key, d))
}

/// Return the equivalent spellings of `key` under each retired domain, newest
/// first, or an empty vector when `key` is not in Kix's current domain.
pub fn legacy_spellings(key: &str) -> Vec<String> {
    let Some(name) = key.strip_prefix(keys::PREFIX) else {
        return Vec::new();
    };
    DOMAINS.iter().map(|d| format!("{d}/{name}")).collect()
}

/// Return whether a live object still carries only a pre-migration identity
/// stamp, where `has` reports whether a specific annotation key is present.
///
/// Returns true during the window between `kix migrate domain` and the next
/// deploy: the cluster records have moved so `check_discovery` (in `kix-lib`) passes, but
/// live objects still carry the retired annotations until a deploy re-applies
/// them. Because an identity hash covers the full manifest and the domain
/// change altered every manifest, live hashes from before the migration do not
/// match fresh build hashes and must not be treated as orphaned resources.
pub fn stamped_before_move<F>(has: F) -> bool
where
    F: Fn(&str) -> bool,
{
    !has(keys::IDENTITY_HASH) && legacy_spellings(keys::IDENTITY_HASH).iter().any(|k| has(k))
}

/// Return every retired Kix annotation key on an object that Kix has just
/// applied.
///
/// Server-side apply drops retired keys only when the `kix` field manager owns
/// them. Objects previously written with client-side `kubectl apply` have no
/// `managedFields` owner for those keys, so server-side apply adds the current
/// key while leaving the retired key alongside it.
///
/// Call this only after a successful apply. The apply wrote the object's full
/// current key set, so any remaining retired key is stale residue that would
/// otherwise cause [`fallback`] to return outdated values when a current key
/// is absent. Never call this on the skipped path, where the object was not
/// re-applied and its retired keys are still authoritative.
pub fn retired_keys(annotations: &std::collections::BTreeMap<String, String>) -> Vec<String> {
    annotations
        .keys()
        .filter(|k| is_legacy_key(k))
        .cloned()
        .collect()
}

/// Look up `key` under each retired domain in turn, using `lookup` to read a
/// single key from the caller's map.
pub(crate) fn fallback<'a, F>(key: &str, lookup: F) -> Option<&'a str>
where
    F: Fn(&str) -> Option<&'a str>,
{
    legacy_spellings(key).into_iter().find_map(|k| lookup(&k))
}

/// Upgrade every Kix annotation, label, and record group on `manifest` to the
/// current domain.
///
/// Called by the store-graph loader and by `kix deploy`'s live reconstruction
/// so the planner, the differ, and the stamper all see a single domain. If a
/// key is already present under the current domain, its value takes
/// precedence over the retired key.
pub fn upgrade_manifest(manifest: &mut Value) {
    upgrade_manifest_from(manifest, DOMAINS);
}

/// Upgrade `manifest` from the given retired `domains` list (a no-op when
/// `domains` is empty).
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
    let ours = [ACTIVATION_PLURAL, PACKAGE_INSTANCE_PLURAL];
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

/// Return the retired spellings of the keys that a merge patch is about to
/// write.
///
/// Called from `cluster::apply`. Server-side apply drops build-time keys
/// automatically because the `kix` field manager owns them, whereas
/// `activations` and `applied-hash` are written by merge patch and must be
/// removed explicitly.
///
/// Only the keys in `writing` are cleared. Clearing a retired key that the
/// patch does not replace (such as `applied-hash` on the skipped path) would
/// leave an unchanged resource without a hash under either domain and disable
/// drift detection for it.
pub fn bookkeeping_null_outs(writing: &[&str]) -> Vec<String> {
    writing.iter().flat_map(|k| legacy_spellings(k)).collect()
}

/// Error returned when a cluster or build uses a retired Kix API group.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum LegacyDomainError {
    #[error(
        "this Kubernetes cluster's deployment records use the retired `{group}` API group\n  \
         Nothing was changed on the cluster.\n\n  \
         Why:\n    \
         This cluster was deployed with an older version of Kix, which stored deployment records under `{group}`. Kix now stores deployment records under `{}`.\n\n  \
         Next:\n    \
         Run the one-time domain migration (replace `<cluster>` with your Kix cluster name; run `kix list clusters` if you need to check the name), then run your command again:\n      \
         kix migrate domain <cluster>",
        keys::GROUP
    )]
    NotMigrated { group: String },

    #[error(
        "domain migration from `{legacy}` to `{current}` on this Kubernetes cluster is unfinished\n  \
         Nothing was changed on the cluster.\n\n  \
         Why:\n    \
         This cluster has deployment records under both `{legacy}` and `{current}` because an earlier `kix migrate domain` run stopped before finishing.\n\n  \
         Next:\n    \
         Run the domain migration again to finish it (replace `<cluster>` with your Kix cluster name; records already copied to `{current}` are skipped), then run your command again:\n      \
         kix migrate domain <cluster>"
    )]
    BothGroups { legacy: String, current: String },

    #[error(
        "this project's Kix library writes deployment records under the retired `{group}` API group\n  \
         Nothing was applied to the cluster.\n\n  \
         Why:\n    \
         Kix now stores deployment records under `{current}`, and deploying this build would put the retired `{group}` resource types back on the cluster.\n\n  \
         Next:\n    \
         Update the Kix library in `flake.lock` to match this version of Kix, commit `flake.lock`, and run the command again:\n      \
         kix lib update"
    )]
    StalePin { group: String, current: String },
}

/// Check the API groups serving Kix record kinds for any retired domain.
///
/// `kix-lib`'s `legacy_domain::check_discovery` collects those groups from
/// API discovery.
pub fn check_cluster(groups_in_discovery: &[&str]) -> Result<(), LegacyDomainError> {
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

/// Check whether a raw build renders Kix's own records or CRDs under a retired
/// API group.
///
/// Rejects builds evaluated against a `kixpkgs` revision from before the
/// domain migration so deploying them cannot re-create the retired CRDs on a
/// migrated cluster. [`crate::build_source::Build`] runs this check before
/// stamping because stamping upgrades manifests to the current domain.
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
            // calling it a stale Kix library would be the wrong diagnosis.
            // The same restraint `upgrade_own_crd` shows.
            && m.pointer("/spec/names/plural")
                .and_then(Value::as_str)
                .is_some_and(|p| {
                    [ACTIVATION_PLURAL, PACKAGE_INSTANCE_PLURAL].contains(&p)
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
        assert_eq!(
            m["metadata"]["labels"][keys::CLUSTER_LABEL],
            json!("stage2")
        );
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

    /// Verify that a third-party CRD in a retired Kix group is not renamed
    /// into `kix.run`.
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
