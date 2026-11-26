//! The objects of a kind that stay on the cluster when the definition of
//! the kind leaves the build.
//!
//! Kix never deletes a CustomResourceDefinition, and deletes only the
//! objects it created. When a package that defines a kind leaves the build,
//! the objects of that kind that someone else created stay, and so does the
//! definition. The package's controller usually leaves too, so nothing
//! removes their finalizers or cleans up what they made outside the cluster,
//! such as a DNS record. The plan lists them so the person can delete them
//! while the controller still runs.

use std::collections::HashSet;

use kube::api::{Api, DynamicObject, ListParams};
use kube::discovery::ApiResource;
use kube::{Client, ResourceExt};

use crate::cluster::readiness::finalizers_of;
use crate::manifest::types::ResourceId;
use crate::plan::document::{LEFT_BEHIND_LISTED, LeftBehind, LeftObject};

/// Return the objects of the kind that the CustomResourceDefinition `crd`
/// defines that are on the cluster and not in `deleting`, or `None` when
/// the definition is not on the cluster or defines no served version.
pub async fn list(
    client: &Client,
    crd: &str,
    deleting: &HashSet<ResourceId>,
) -> Result<Option<LeftBehind>, kube::Error> {
    let crds: Api<DynamicObject> = Api::all_with(
        client.clone(),
        &ApiResource {
            group: "apiextensions.k8s.io".into(),
            version: "v1".into(),
            api_version: "apiextensions.k8s.io/v1".into(),
            kind: "CustomResourceDefinition".into(),
            plural: "customresourcedefinitions".into(),
        },
    );
    let Some(definition) = crds.get_opt(crd).await? else {
        return Ok(None);
    };
    let Some(ar) = served_resource(&definition.data) else {
        return Ok(None);
    };
    let api: Api<DynamicObject> = Api::all_with(client.clone(), &ar);
    let mut objects: Vec<LeftObject> = api
        .list(&ListParams::default())
        .await?
        .items
        .into_iter()
        .filter_map(|obj| {
            let rid = ResourceId::new(
                &ar.group,
                &ar.kind,
                obj.namespace()
                    .as_deref()
                    .unwrap_or(crate::manifest::types::CLUSTER_SCOPED),
                &obj.name_any(),
            );
            (!deleting.contains(&rid)).then(|| LeftObject {
                resource: rid.display_id(),
                finalizers: finalizers_of(&obj),
            })
        })
        .collect();
    let kind = crate::manifest::types::qualified_kind(&ar.group, &ar.kind);
    Ok(Some(of_objects(kind, &mut objects)))
}

/// Return the [`LeftBehind`] of `objects`, naming those with finalizers
/// first, then by name.
fn of_objects(kind: String, objects: &mut Vec<LeftObject>) -> LeftBehind {
    objects.sort_by(|a, b| {
        a.finalizers
            .is_empty()
            .cmp(&b.finalizers.is_empty())
            .then_with(|| a.resource.cmp(&b.resource))
    });
    let count = objects.len();
    objects.truncate(LEFT_BEHIND_LISTED);
    LeftBehind {
        kind,
        count,
        objects: std::mem::take(objects),
    }
}

/// Return the API of the storage version of a CustomResourceDefinition, or
/// of its first served version when no served version is the storage one.
fn served_resource(spec: &serde_json::Value) -> Option<ApiResource> {
    let spec = spec.get("spec")?;
    let group = spec.get("group")?.as_str()?;
    let names = spec.get("names")?;
    let versions = spec.get("versions")?.as_array()?;
    let served: Vec<&serde_json::Value> = versions
        .iter()
        .filter(|v| v.get("served").and_then(|s| s.as_bool()) == Some(true))
        .collect();
    let version = served
        .iter()
        .find(|v| v.get("storage").and_then(|s| s.as_bool()) == Some(true))
        .or(served.first())?
        .get("name")?
        .as_str()?;
    Some(ApiResource {
        group: group.into(),
        version: version.into(),
        api_version: format!("{group}/{version}"),
        kind: names.get("kind")?.as_str()?.into(),
        plural: names.get("plural")?.as_str()?.into(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;
    use serde_json::json;

    fn widget_crd() -> serde_json::Value {
        json!({
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": { "name": "widgets.example.com" },
            "spec": {
                "group": "example.com",
                "names": { "kind": "Widget", "plural": "widgets" },
                "scope": "Namespaced",
                "versions": [
                    { "name": "v1", "served": true, "storage": true },
                ],
            },
        })
    }

    #[test]
    fn the_storage_version_is_listed() {
        let mut crd = widget_crd();
        crd["spec"]["versions"] = json!([
            { "name": "v1beta1", "served": true, "storage": false },
            { "name": "v1", "served": true, "storage": true },
            { "name": "v2", "served": false, "storage": false },
        ]);
        let ar = served_resource(&crd).unwrap();
        assert_eq!(
            (ar.api_version.as_str(), ar.plural.as_str()),
            ("example.com/v1", "widgets")
        );
        crd["spec"]["versions"] = json!([{ "name": "v1", "served": false, "storage": true }]);
        assert!(served_resource(&crd).is_none());
    }

    #[test]
    fn objects_with_finalizers_come_first_and_the_list_is_cut() {
        let mut objects: Vec<LeftObject> = (0..LEFT_BEHIND_LISTED + 5)
            .map(|i| LeftObject {
                resource: format!("Widget.example.com/w{i:02}@app"),
                finalizers: if i == 7 {
                    vec!["example.com/cleanup".into()]
                } else {
                    Vec::new()
                },
            })
            .collect();
        let left = of_objects("Widget.example.com".into(), &mut objects);
        assert_eq!(left.count, LEFT_BEHIND_LISTED + 5);
        assert_eq!(left.objects.len(), LEFT_BEHIND_LISTED);
        assert_eq!(left.objects[0].resource, "Widget.example.com/w07@app");
        assert_eq!(left.objects[1].resource, "Widget.example.com/w00@app");
    }

    /// The objects the prune deletes are not listed. A definition that is
    /// not on the cluster lists nothing.
    #[tokio::test]
    async fn objects_the_prune_deletes_are_left_out() {
        use crate::cluster::fake_api::TWO_VERSION_GROUP as GROUP;
        let gizmo = |name: &str, finalizers: serde_json::Value| {
            json!({
                "apiVersion": format!("{GROUP}/v1"),
                "kind": "Gizmo",
                "metadata": { "name": name, "namespace": "app", "finalizers": finalizers },
            })
        };
        let crd = json!({
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": { "name": format!("gizmos.{GROUP}") },
            "spec": {
                "group": GROUP,
                "names": { "kind": "Gizmo", "plural": "gizmos" },
                "scope": "Namespaced",
                "versions": [{ "name": "v1", "served": true, "storage": true }],
            },
        });
        let api = FakeApi::new([
            crd,
            gizmo("made-by-hand", json!(["example.com/cleanup"])),
            gizmo("made-by-kix", json!([])),
        ]);
        let client = api.client();
        let deleting: HashSet<ResourceId> =
            [ResourceId::new(GROUP, "Gizmo", "app", "made-by-kix")].into();
        let left = list(&client, &format!("gizmos.{GROUP}"), &deleting)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(left.kind, format!("Gizmo.{GROUP}"));
        assert_eq!(left.count, 1);
        assert_eq!(
            left.objects[0].resource,
            format!("Gizmo.{GROUP}/made-by-hand@app")
        );
        assert_eq!(left.objects[0].finalizers, ["example.com/cleanup"]);
        assert!(
            list(&client, "gadgets.example.com", &deleting)
                .await
                .unwrap()
                .is_none()
        );
    }
}
