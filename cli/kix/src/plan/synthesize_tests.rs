//! How a live side that `StoreGraph::synthesize` rebuilt compares with a
//! build, for objects that moved between packages.

use serde_json::{Value, json};

use crate::eval::fixtures::*;
use crate::eval::package_index::RecordPackageIndex;
use crate::eval::store_graph::StoreGraph;
use crate::manifest::types::ResourceId;

/// After a failed deploy, a live import marker carries another
/// identity hash than the new build's, and its stamp says `_cluster`
/// or names another package. It stays under the package that declares
/// it in the build, as a changed resource, and is not a removed
/// package.
#[test]
fn a_marker_whose_hash_moved_stays_under_its_declaring_package() {
    let build = built(&[(
        "pi",
        rendered_pi("other-ns", "other", None),
        vec![
            ("cm", rendered("ConfigMap", "other-ns", "other")),
            (
                "mk",
                rendered_pi(
                    "other-ns",
                    "secret-ref-other-mcp-token",
                    Some(("Secret", "mcp-token")),
                ),
            ),
        ],
    )]);
    for stamp in ["_cluster", "elsewhere"] {
        let old = StoreGraph::synthesize(&after_failed_deploy(&build, stamp), &build);
        assert_eq!(old.packages.len(), 1, "stamp {stamp}");
        assert_eq!(
            names_in(&old, "other-ns", "other"),
            vec!["other", "secret-ref-other-mcp-token"],
        );
        let d = crate::plan::diff_graphs(&old, &build);
        assert!(d.removed.is_empty() && d.added.is_empty(), "stamp {stamp}");
        assert_eq!(d.changed.len(), 1);
    }
}

/// An object that moved from package `old` to package `web` and also
/// changed shows only as a change inside `web`, because the build
/// decides where it goes. `old` shows no removal. This pins the
/// limit, so a change to it is deliberate.
#[test]
fn a_moved_and_changed_object_shows_only_under_its_new_package() {
    let build = built(&[(
        "pi",
        rendered_pi("app", "web", None),
        vec![("cm", rendered("ConfigMap", "app", "settings"))],
    )]);
    let mut live: Vec<Value> = build
        .resources
        .values()
        .filter(|n| n.manifest["kind"] != "ConfigMap")
        .map(|n| n.manifest.clone())
        .collect();
    live.push(stamped(
        "ConfigMap",
        "app",
        "settings",
        ("app", "old"),
        &h("before-move"),
        json!({"k": "v"}),
    ));

    let old = StoreGraph::synthesize(&live, &build);
    assert_eq!(names_in(&old, "app", "web"), vec!["settings"]);
    let d = crate::plan::diff_graphs(&old, &build);
    assert!(d.removed.is_empty() && d.added.is_empty());
    assert_eq!(d.changed.len(), 1);
    assert_eq!(d.changed[0].key, "app/web");
}

/// With the deployed record's package index, the same move shows
/// `settings` removed from `old` and added to `web`, as a comparison
/// with the deployed build does. An index in another format is not
/// read, and the move shows only under `web` again.
#[test]
fn a_moved_and_changed_object_shows_under_both_packages_with_an_index() {
    let build = built(&[
        (
            "pi",
            rendered_pi("app", "web", None),
            vec![("cm", rendered("ConfigMap", "app", "settings"))],
        ),
        ("pi-old", rendered_pi("app", "old", None), vec![]),
    ]);
    let mut live: Vec<Value> = build
        .resources
        .values()
        .filter(|n| n.manifest["kind"] != "ConfigMap")
        .map(|n| n.manifest.clone())
        .collect();
    live.push(stamped(
        "ConfigMap",
        "app",
        "settings",
        ("app", "old"),
        &h("before-move"),
        json!({"k": "v"}),
    ));
    let deployed: RecordPackageIndex = serde_json::from_value(json!({
        "format": crate::eval::package_index::FORMAT,
        "packages": {
            "app/old": { "instance": h("pi-old"), "resources": [h("before-move")] },
            "app/web": { "instance": h("pi"), "resources": [] },
        },
        "clusterLevel": [],
    }))
    .unwrap();

    let old = StoreGraph::synthesize_placed(&live, &build, &[&deployed]);
    assert_eq!(names_in(&old, "app", "old"), vec!["settings"]);
    assert!(names_in(&old, "app", "web").is_empty());
    let d = crate::plan::diff_graphs(&old, &build);
    let change = |key: &str| d.changed.iter().find(|c| c.key == key).unwrap();
    let settings = ResourceId::from_value(&live[live.len() - 1]);
    assert_eq!(change("app/old").removed_resources, vec![settings.clone()]);
    assert_eq!(change("app/web").added_resources, vec![settings]);

    let mut unknown = deployed.to_value();
    unknown["format"] = json!(crate::eval::package_index::FORMAT + 1);
    let unread: Vec<RecordPackageIndex> = RecordPackageIndex::from_value(&unknown)
        .into_iter()
        .collect();
    let unread: Vec<&RecordPackageIndex> = unread.iter().collect();
    let old = StoreGraph::synthesize_placed(&live, &build, &unread);
    assert_eq!(names_in(&old, "app", "web"), vec!["settings"]);
}
