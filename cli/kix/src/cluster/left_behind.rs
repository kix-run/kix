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

use std::collections::{HashMap, HashSet};

use kube::api::{Api, DynamicObject, ListParams};
use kube::discovery::ApiResource;
use kube::{Client, ResourceExt};

use crate::cluster::readiness::finalizers_of;
use crate::manifest::types::ResourceId;
use crate::plan::document::{LEFT_BEHIND_LISTED, LeftBehind, LeftObject};

/// The live objects of the kind one CustomResourceDefinition defines.
#[derive(Debug, Clone)]
pub struct Listed {
    /// The definition's name.
    pub crd: String,
    /// The kind, as `Kind.group`.
    pub kind: String,
    objects: Vec<ListedObject>,
}

#[derive(Debug, Clone)]
struct ListedObject {
    rid: ResourceId,
    uid: Option<String>,
    finalizers: Vec<String>,
    owners: Vec<Owner>,
}

/// An entry of an object's `metadata.ownerReferences`.
#[derive(Debug, Clone)]
struct Owner {
    group: String,
    kind: String,
    name: String,
    uid: String,
}

/// Return the objects of the kind that the CustomResourceDefinition `crd`
/// defines, or `None` when the definition is not on the cluster or defines
/// no served version.
pub async fn list(client: &Client, crd: &str) -> Result<Option<Listed>, kube::Error> {
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
    let objects = api
        .list(&ListParams::default())
        .await?
        .items
        .into_iter()
        .map(|obj| ListedObject {
            rid: ResourceId::new(
                &ar.group,
                &ar.kind,
                obj.namespace()
                    .as_deref()
                    .unwrap_or(crate::manifest::types::CLUSTER_SCOPED),
                &obj.name_any(),
            ),
            uid: obj.metadata.uid.clone(),
            finalizers: finalizers_of(&obj),
            owners: obj
                .metadata
                .owner_references
                .iter()
                .flatten()
                .map(|r| Owner {
                    group: crate::manifest::types::api_group(&r.api_version).to_string(),
                    kind: r.kind.clone(),
                    name: r.name.clone(),
                    uid: r.uid.clone(),
                })
                .collect(),
        })
        .collect();
    Ok(Some(Listed {
        crd: crd.to_string(),
        kind: crate::manifest::types::qualified_kind(&ar.group, &ar.kind),
        objects,
    }))
}

/// Return, for each definition of `listed` by name, the objects that stay
/// on the cluster after a prune that deletes `deleting`. An object the prune
/// deletes does not stay. Neither does an object that names one of those as
/// an owner, directly or through other listed objects, because Kubernetes
/// deletes it with its owner. A definition with no object left is not
/// returned.
pub fn left_behind(
    listed: &[Listed],
    deleting: &HashSet<ResourceId>,
) -> HashMap<String, LeftBehind> {
    let objects: Vec<&ListedObject> = listed.iter().flat_map(|l| &l.objects).collect();
    let deleted_owner = |o: &ListedObject, owner: &Owner| {
        [
            o.rid.namespace.as_str(),
            crate::manifest::types::CLUSTER_SCOPED,
        ]
        .iter()
        .any(|ns| deleting.contains(&ResourceId::new(&owner.group, &owner.kind, ns, &owner.name)))
    };
    let mut going: HashSet<&str> = HashSet::new();
    let goes = |o: &ListedObject, going: &HashSet<&str>| {
        deleting.contains(&o.rid)
            || o.owners
                .iter()
                .any(|owner| going.contains(owner.uid.as_str()) || deleted_owner(o, owner))
    };
    loop {
        let before = going.len();
        for o in &objects {
            if let Some(uid) = o.uid.as_deref()
                && !going.contains(uid)
                && goes(o, &going)
            {
                going.insert(uid);
            }
        }
        if going.len() == before {
            break;
        }
    }
    listed
        .iter()
        .filter_map(|l| {
            let mut stay: Vec<LeftObject> = l
                .objects
                .iter()
                .filter(|o| !goes(o, &going))
                .map(|o| LeftObject {
                    resource: o.rid.display_id(),
                    finalizers: o.finalizers.clone(),
                })
                .collect();
            (!stay.is_empty()).then(|| (l.crd.clone(), of_objects(l.kind.clone(), &mut stay)))
        })
        .collect()
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
    let with_finalizers = objects.iter().filter(|o| !o.finalizers.is_empty()).count();
    objects.truncate(LEFT_BEHIND_LISTED);
    LeftBehind {
        kind,
        count,
        with_finalizers,
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

    /// Listing a kind reads each object's finalizers and owners. A
    /// definition that is not on the cluster lists nothing.
    #[tokio::test]
    async fn a_kind_is_listed_with_finalizers_and_owners() {
        use crate::cluster::fake_api::TWO_VERSION_GROUP as GROUP;
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
            json!({
                "apiVersion": format!("{GROUP}/v1"),
                "kind": "Gizmo",
                "metadata": {
                    "name": "g",
                    "namespace": "app",
                    "finalizers": ["example.com/cleanup"],
                    "ownerReferences": [{
                        "apiVersion": "example.com/v1", "kind": "Widget", "name": "w", "uid": "uid-w",
                    }],
                },
            }),
        ]);
        let client = api.client();
        let listed = list(&client, &format!("gizmos.{GROUP}"))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(listed.kind, format!("Gizmo.{GROUP}"));
        let o = &listed.objects[0];
        assert_eq!(o.rid, ResourceId::new(GROUP, "Gizmo", "app", "g"));
        assert_eq!(o.finalizers, ["example.com/cleanup"]);
        assert_eq!(
            (o.owners[0].group.as_str(), o.owners[0].uid.as_str()),
            ("example.com", "uid-w")
        );
        assert!(
            list(&client, "gadgets.example.com")
                .await
                .unwrap()
                .is_none()
        );
    }

    fn object(kind: &str, name: &str, uid: &str, owners: &[(&str, &str, &str)]) -> ListedObject {
        ListedObject {
            rid: ResourceId::new("example.com", kind, "app", name),
            uid: Some(uid.into()),
            finalizers: Vec::new(),
            owners: owners
                .iter()
                .map(|(kind, name, uid)| Owner {
                    group: "example.com".into(),
                    kind: (*kind).into(),
                    name: (*name).into(),
                    uid: (*uid).into(),
                })
                .collect(),
        }
    }

    /// An object the prune deletes does not stay, nor does an object owned,
    /// directly or through another listed object, by one the prune deletes.
    /// An unowned object of the same kind, and one whose owner stays, are
    /// still listed.
    #[test]
    fn objects_owned_by_what_the_prune_deletes_do_not_stay() {
        let listed = vec![
            Listed {
                crd: "scripts.example.com".into(),
                kind: "Script.example.com".into(),
                objects: vec![
                    object("Script", "owned", "u1", &[("Cluster", "db", "uid-db")]),
                    object("Script", "by-hand", "u2", &[]),
                ],
            },
            Listed {
                crd: "orders.example.com".into(),
                kind: "Order.example.com".into(),
                objects: vec![
                    object(
                        "Order",
                        "under-kix",
                        "u3",
                        &[("Cert", "kix-cert", "uid-kc")],
                    ),
                    object(
                        "Order",
                        "under-hand",
                        "u4",
                        &[("Cert", "hand-cert", "uid-hc")],
                    ),
                ],
            },
            Listed {
                crd: "challenges.example.com".into(),
                kind: "Challenge.example.com".into(),
                objects: vec![
                    object("Challenge", "c1", "u5", &[("Order", "under-kix", "u3")]),
                    object("Challenge", "c2", "u6", &[("Order", "under-hand", "u4")]),
                ],
            },
            Listed {
                crd: "deleted.example.com".into(),
                kind: "Gone.example.com".into(),
                objects: vec![object("Gone", "kix-made", "u7", &[])],
            },
        ];
        let deleting: HashSet<ResourceId> = [
            ResourceId::new("example.com", "Cluster", "app", "db"),
            ResourceId::new("example.com", "Cert", "app", "kix-cert"),
            ResourceId::new("example.com", "Gone", "app", "kix-made"),
        ]
        .into();
        let left = left_behind(&listed, &deleting);
        let names = |crd: &str| -> Vec<String> {
            left[crd]
                .objects
                .iter()
                .map(|o| o.resource.clone())
                .collect()
        };
        assert_eq!(
            names("scripts.example.com"),
            ["Script.example.com/by-hand@app"]
        );
        assert_eq!(
            names("orders.example.com"),
            ["Order.example.com/under-hand@app"]
        );
        assert_eq!(
            names("challenges.example.com"),
            ["Challenge.example.com/c2@app"]
        );
        assert!(!left.contains_key("deleted.example.com"));
    }
}
