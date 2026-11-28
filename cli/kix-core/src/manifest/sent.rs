//! The manifest Kix sends to the API server for a built object.
//!
//! A built manifest carries annotations that describe one Kix cluster's
//! dependency graph. The scheduler, the graph commands, bundles, and stored
//! builds read them from the build. They are not part of what the
//! definition says about the object, and two Kix clusters that share an
//! object would conflict on them, so they stay off the cluster.
//!
//! Every request that sends a built manifest, and every comparison of a
//! built manifest with a live object or a dry-run result, takes the
//! manifest through [`of`].
//!
//! The retired notes ([`is_retired_note`]) are the graph notes and the two
//! notes an older Kix wrote after each apply. Kix never sends one, leaves
//! them out of every hash it stores, and the migration write removes them
//! from objects.

use std::borrow::Cow;

use serde_json::Value;

use super::keys;
use super::lifecycle::is_record;

/// The annotations [`of`] removes from a built manifest. Each describes one
/// Kix cluster's graph: the object's build hash, the build hashes it depends
/// on, and the package instance it belongs to. A revision records the same
/// facts by name.
pub const GRAPH_NOTES: &[&str] = &[
    keys::IDENTITY_HASH,
    keys::DEPENDS_ON,
    keys::PACKAGE,
    keys::PACKAGE_NAMESPACE,
    keys::LIFECYCLE,
];

/// The annotations an older Kix wrote to an object after applying it, which
/// revisions hold now.
const AFTER_APPLY_NOTES: &[&str] = &[keys::ACTIVATIONS, keys::APPLIED_HASH];

/// Return whether `key` is a retired note: one of [`GRAPH_NOTES`],
/// `kix.run/activations`, or `kix.run/applied-hash`, under Kix's domain or a
/// retired one.
pub fn is_retired_note(key: &str) -> bool {
    GRAPH_NOTES.iter().chain(AFTER_APPLY_NOTES).any(|note| {
        *note == key
            || crate::legacy_domain::legacy_spellings(note)
                .iter()
                .any(|k| k == key)
    })
}

/// Remove every retired note from the annotations of `manifest`, and the
/// `annotations` map when that leaves it empty.
pub fn strip_retired_notes(manifest: &mut Value) {
    let Some(meta) = manifest.get_mut("metadata").and_then(Value::as_object_mut) else {
        return;
    };
    let emptied = meta
        .get_mut("annotations")
        .and_then(Value::as_object_mut)
        .is_some_and(|a| {
            a.retain(|k, _| !is_retired_note(k));
            a.is_empty()
        });
    if emptied {
        meta.remove("annotations");
    }
}

/// Return the manifest Kix sends for the built manifest `manifest`: the
/// manifest without the retired notes ([`is_retired_note`]), and without
/// its `annotations` map when that leaves it empty. What this removes is
/// what every hash Kix stores leaves out.
///
/// Kix's own Activation record is returned as it is. It belongs to one Kix
/// cluster, and its build hash annotation says which build it records:
/// Kix reads that annotation from the live record.
pub fn of(manifest: &Value) -> Cow<'_, Value> {
    let carries = manifest
        .pointer("/metadata/annotations")
        .and_then(Value::as_object)
        .is_some_and(|a| a.keys().any(|k| is_retired_note(k)));
    if !carries || is_record(manifest) {
        return Cow::Borrowed(manifest);
    }
    let mut out = manifest.clone();
    strip_retired_notes(&mut out);
    Cow::Owned(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::keys;
    use crate::manifest::lifecycle::RECORD_KIND;
    use serde_json::json;

    fn config_map(annotations: Value) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": { "name": "app", "namespace": "web", "annotations": annotations },
            "data": { "k": "v" },
        })
    }

    #[test]
    fn the_notes_are_removed_and_every_other_annotation_stays() {
        let built = config_map(json!({
            keys::IDENTITY_HASH: "h1",
            keys::DEPENDS_ON: "h2",
            keys::READINESS: "none",
            "example.com/owner": "team",
        }));
        let sent = of(&built);
        assert!(matches!(sent, Cow::Owned(_)));
        assert_eq!(
            *sent,
            config_map(json!({ keys::READINESS: "none", "example.com/owner": "team" }))
        );
    }

    #[test]
    fn annotations_left_empty_are_removed() {
        let built = config_map(json!({ keys::IDENTITY_HASH: "h1", keys::DEPENDS_ON: "h2" }));
        let sent = of(&built);
        assert_eq!(sent.pointer("/metadata/annotations"), None);
        assert_eq!(sent.pointer("/data/k"), Some(&json!("v")));
    }

    #[test]
    fn a_manifest_without_notes_is_borrowed() {
        let built = config_map(json!({ "example.com/owner": "team" }));
        assert!(matches!(of(&built), Cow::Borrowed(_)));
        let bare = json!({ "apiVersion": "v1", "kind": "ConfigMap", "metadata": { "name": "a" } });
        assert!(matches!(of(&bare), Cow::Borrowed(_)));
    }

    #[test]
    fn the_activation_record_keeps_its_annotations() {
        let record = json!({
            "apiVersion": keys::API_VERSION,
            "kind": RECORD_KIND,
            "metadata": {
                "name": "lab-abc",
                "annotations": { keys::IDENTITY_HASH: "h1", keys::DEPENDS_ON: "h2" },
            },
        });
        assert!(matches!(of(&record), Cow::Borrowed(_)));
    }

    /// What Kix sends leaves out exactly the retired notes, every one of
    /// them under every domain, so a manifest that carries one, copied from
    /// a dump of a live object for example, is not sent with it.
    #[test]
    fn of_removes_every_retired_note() {
        let mut annotations = serde_json::Map::new();
        for note in GRAPH_NOTES.iter().chain(AFTER_APPLY_NOTES) {
            annotations.insert(note.to_string(), json!("x"));
            for old in crate::legacy_domain::legacy_spellings(note) {
                annotations.insert(old, json!("x"));
            }
        }
        annotations.insert(keys::READINESS.into(), json!("none"));
        let built = config_map(Value::Object(annotations));
        assert_eq!(*of(&built), config_map(json!({ keys::READINESS: "none" })));
    }

    #[test]
    fn the_retired_notes_are_seven_under_each_domain() {
        let notes = [
            keys::IDENTITY_HASH,
            keys::DEPENDS_ON,
            keys::PACKAGE,
            keys::PACKAGE_NAMESPACE,
            keys::LIFECYCLE,
            keys::ACTIVATIONS,
            keys::APPLIED_HASH,
        ];
        for note in notes {
            assert!(is_retired_note(note), "{note}");
            for old in crate::legacy_domain::legacy_spellings(note) {
                assert!(is_retired_note(&old), "{old}");
            }
        }
        for kept in [
            keys::READINESS,
            keys::SOPS_DIGEST,
            keys::SOPS_SOURCE,
            keys::RERUN_HASH,
        ] {
            assert!(!is_retired_note(kept), "{kept}");
        }
        let mut m = config_map(json!({ keys::APPLIED_HASH: "a", keys::PACKAGE: "p" }));
        strip_retired_notes(&mut m);
        assert_eq!(m.pointer("/metadata/annotations"), None);
    }
}
