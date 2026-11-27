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

use std::borrow::Cow;

use serde_json::Value;

use super::lifecycle::is_record;

/// The annotations [`of`] removes from a built manifest.
pub const GRAPH_NOTES: &[&str] = &[];

/// Return the manifest Kix sends for the built manifest `manifest`: the
/// manifest without the annotations in [`GRAPH_NOTES`].
///
/// Kix's own Activation record is returned as it is. It belongs to one Kix
/// cluster, and its annotations say which build it records.
pub fn of(manifest: &Value) -> Cow<'_, Value> {
    without(manifest, GRAPH_NOTES)
}

/// Return `manifest` without the annotations `notes`, leaving an Activation
/// record as it is. An `annotations` map left empty is removed.
fn without<'a>(manifest: &'a Value, notes: &[&str]) -> Cow<'a, Value> {
    let carries = |a: &serde_json::Map<String, Value>| notes.iter().any(|n| a.contains_key(*n));
    let Some(annotations) = manifest
        .pointer("/metadata/annotations")
        .and_then(Value::as_object)
    else {
        return Cow::Borrowed(manifest);
    };
    if !carries(annotations) || is_record(manifest) {
        return Cow::Borrowed(manifest);
    }
    let mut out = manifest.clone();
    if let Some(meta) = out.get_mut("metadata").and_then(Value::as_object_mut) {
        let emptied = meta
            .get_mut("annotations")
            .and_then(Value::as_object_mut)
            .is_some_and(|a| {
                for note in notes {
                    a.remove(*note);
                }
                a.is_empty()
            });
        if emptied {
            meta.remove("annotations");
        }
    }
    Cow::Owned(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::keys;
    use crate::manifest::lifecycle::RECORD_KIND;
    use serde_json::json;

    const NOTES: &[&str] = &[keys::IDENTITY_HASH, keys::DEPENDS_ON];

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
        let sent = without(&built, NOTES);
        assert!(matches!(sent, Cow::Owned(_)));
        assert_eq!(
            *sent,
            config_map(json!({ keys::READINESS: "none", "example.com/owner": "team" }))
        );
    }

    #[test]
    fn annotations_left_empty_are_removed() {
        let built = config_map(json!({ keys::IDENTITY_HASH: "h1", keys::DEPENDS_ON: "h2" }));
        let sent = without(&built, NOTES);
        assert_eq!(sent.pointer("/metadata/annotations"), None);
        assert_eq!(sent.pointer("/data/k"), Some(&json!("v")));
    }

    #[test]
    fn a_manifest_without_notes_is_borrowed() {
        let built = config_map(json!({ "example.com/owner": "team" }));
        assert!(matches!(without(&built, NOTES), Cow::Borrowed(_)));
        let bare = json!({ "apiVersion": "v1", "kind": "ConfigMap", "metadata": { "name": "a" } });
        assert!(matches!(without(&bare, NOTES), Cow::Borrowed(_)));
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
        assert!(matches!(without(&record, NOTES), Cow::Borrowed(_)));
    }

    #[test]
    fn of_removes_the_graph_notes() {
        let built = config_map(json!({ keys::IDENTITY_HASH: "h1", keys::DEPENDS_ON: "h2" }));
        assert_eq!(*of(&built), *without(&built, GRAPH_NOTES));
    }
}
