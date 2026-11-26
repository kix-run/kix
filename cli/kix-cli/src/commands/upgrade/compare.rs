//! Compare a cluster's manifests before and after an upgrade, and say which
//! changes touch access, network reach, or encryption.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use kix::manifest::hash::strip_kix_annotations;
use kix::manifest::keys;
use kix::manifest::kinds::{self, GroupKind};
use kix::manifest::lifecycle::{is_kix_crd, is_kix_internal_kind};
use kix::manifest::types::ResourceId;
use serde_json::Value;

/// One object of a built cluster.
#[derive(Debug, Clone, PartialEq)]
pub struct Object {
    /// The instance the object belongs to, from its `kix.run/package`
    /// annotation.
    pub package: Option<String>,
    /// The manifest without Kix's annotations, which change with every
    /// build.
    pub manifest: Value,
}

/// Read every manifest in `dir` and its subdirectories, keyed by its display
/// id. Kix's own records (Activation, PackageInstance) and their definitions
/// are left out.
pub fn load_dir(dir: &Path) -> Result<BTreeMap<String, Object>, String> {
    let mut out = BTreeMap::new();
    let mut pending = vec![dir.to_path_buf()];
    while let Some(d) = pending.pop() {
        let entries =
            std::fs::read_dir(&d).map_err(|e| format!("could not read {}: {e}", d.display()))?;
        for entry in entries {
            let path = entry
                .map_err(|e| format!("could not read {}: {e}", d.display()))?
                .path();
            if path.is_dir() {
                pending.push(path);
                continue;
            }
            if path.extension().is_none_or(|e| e != "yaml") {
                continue;
            }
            let text = std::fs::read_to_string(&path)
                .map_err(|e| format!("could not read {}: {e}", path.display()))?;
            let mut manifest: Value = kix::yaml::from_str(&text)
                .map_err(|e| format!("{} is not a manifest: {e}", path.display()))?;
            let id = ResourceId::from_value(&manifest);
            if is_kix_internal_kind(&id.kind) || is_kix_crd(&manifest) {
                continue;
            }
            let package = manifest
                .pointer("/metadata/annotations")
                .and_then(|a| a.get(keys::PACKAGE))
                .and_then(Value::as_str)
                .map(str::to_string);
            strip_kix_annotations(&mut manifest);
            out.insert(id.display_id(), Object { package, manifest });
        }
    }
    Ok(out)
}

/// How an object differs after the upgrade.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Change {
    Added,
    Removed,
    Changed,
}

/// One object that differs after the upgrade.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct ObjectChange {
    pub id: String,
    pub change: Change,
    pub package: Option<String>,
    /// The label a person reviews the change under, such as `ClusterRole`
    /// or `Ingress TLS`, when the object controls access, network reach, or
    /// encryption.
    pub review: Option<String>,
}

/// The kinds whose every change a person should read.
const SENSITIVE_KINDS: &[GroupKind<'static>] = &[
    kinds::SECRET,
    kinds::ROLE,
    kinds::CLUSTER_ROLE,
    kinds::ROLE_BINDING,
    kinds::CLUSTER_ROLE_BINDING,
    kinds::NETWORK_POLICY,
    GroupKind::new("cilium.io", "CiliumNetworkPolicy"),
    GroupKind::new("cilium.io", "CiliumClusterwideNetworkPolicy"),
    GroupKind::new("cert-manager.io", "Certificate"),
];

/// Return the TLS settings of an Ingress or a Gateway.
fn tls(manifest: &Value) -> Value {
    match GroupKind::of_manifest(manifest) {
        kinds::INGRESS => manifest["spec"]["tls"].clone(),
        kinds::GATEWAY => Value::Array(
            manifest["spec"]["listeners"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|l| l["tls"].clone())
                .collect(),
        ),
        _ => Value::Null,
    }
}

/// Return the label a person reviews a change from `before` to `after` under,
/// or `None` when the change is not sensitive.
pub fn review(
    kind: GroupKind<'_>,
    before: Option<&Value>,
    after: Option<&Value>,
) -> Option<String> {
    if SENSITIVE_KINDS.contains(&kind) {
        return Some(kind.kind.to_string());
    }
    let tls_kind = matches!(kind, kinds::INGRESS | kinds::GATEWAY);
    (tls_kind && tls_changed(before, after)).then(|| format!("{} TLS", kind.kind))
}

/// Return whether the TLS settings of an Ingress or a Gateway differ
/// between `before` and `after`.
fn tls_changed(before: Option<&Value>, after: Option<&Value>) -> bool {
    let tls_of = |m: Option<&Value>| m.map(tls).unwrap_or(Value::Null);
    let (old, new) = (tls_of(before), tls_of(after));
    old != new && !(is_empty(&old) && is_empty(&new))
}

fn is_empty(v: &Value) -> bool {
    match v {
        Value::Null => true,
        Value::Array(items) => items.iter().all(is_empty),
        _ => false,
    }
}

/// Compare one cluster's objects.
pub fn compare(
    before: &BTreeMap<String, Object>,
    after: &BTreeMap<String, Object>,
) -> Vec<ObjectChange> {
    let ids: BTreeSet<&String> = before.keys().chain(after.keys()).collect();
    let mut out = Vec::new();
    for id in ids {
        let (old, new) = (before.get(id), after.get(id));
        let change = match (old, new) {
            (None, Some(_)) => Change::Added,
            (Some(_), None) => Change::Removed,
            (Some(o), Some(n)) if o.manifest != n.manifest => Change::Changed,
            _ => continue,
        };
        let either = new.or(old).expect("one side holds the object");
        let package = either.package.clone();
        let kind = GroupKind::of_manifest(&either.manifest);
        out.push(ObjectChange {
            id: id.clone(),
            change,
            review: review(kind, old.map(|o| &o.manifest), new.map(|n| &n.manifest)),
            package,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn object(package: &str, manifest: Value) -> Object {
        Object {
            package: Some(package.into()),
            manifest,
        }
    }

    fn deployment(image: &str) -> Value {
        json!({"apiVersion": "apps/v1", "kind": "Deployment",
               "metadata": {"name": "web", "namespace": "shop"},
               "spec": {"image": image}})
    }

    #[test]
    fn objects_are_added_removed_and_changed() {
        let before = BTreeMap::from([
            (
                "Deployment/web@shop".to_string(),
                object("web", deployment("a")),
            ),
            (
                "Secret/old@shop".to_string(),
                object("web", json!({"apiVersion": "v1", "kind": "Secret"})),
            ),
            (
                "ConfigMap/same@shop".to_string(),
                object("db", json!({"apiVersion": "v1", "kind": "ConfigMap"})),
            ),
        ]);
        let after = BTreeMap::from([
            (
                "Deployment/web@shop".to_string(),
                object("web", deployment("b")),
            ),
            (
                "ConfigMap/same@shop".to_string(),
                object("db", json!({"apiVersion": "v1", "kind": "ConfigMap"})),
            ),
            (
                "ClusterRole/new".to_string(),
                object(
                    "db",
                    json!({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole"}),
                ),
            ),
        ]);
        let got = compare(&before, &after);
        let view: Vec<(&str, Change, bool)> = got
            .iter()
            .map(|c| (c.id.as_str(), c.change, c.review.is_some()))
            .collect();
        assert_eq!(
            view,
            [
                ("ClusterRole/new", Change::Added, true),
                ("Deployment/web@shop", Change::Changed, false),
                ("Secret/old@shop", Change::Removed, true),
            ]
        );
    }

    #[test]
    fn an_ingress_or_gateway_is_sensitive_when_its_tls_changes() {
        let ingress = |tls: Value| json!({"apiVersion": "networking.k8s.io/v1", "kind": "Ingress", "spec": {"rules": [], "tls": tls}});
        let a = ingress(json!([{"secretName": "a"}]));
        let b = ingress(json!([{"secretName": "b"}]));
        let label = |before, after| review(kinds::INGRESS, before, after);
        assert_eq!(label(Some(&a), Some(&b)).as_deref(), Some("Ingress TLS"));
        assert_eq!(label(Some(&a), Some(&a)), None);
        let plain = json!({"apiVersion": "networking.k8s.io/v1", "kind": "Ingress", "spec": {"rules": [1]}});
        assert_eq!(label(None, Some(&plain)), None);
        assert!(label(None, Some(&a)).is_some());

        let gateway = |tls: Value| {
            json!({"apiVersion": "gateway.networking.k8s.io/v1", "kind": "Gateway",
                   "spec": {"listeners": [{"name": "h", "tls": tls}]}})
        };
        let terminate = gateway(json!({"mode": "Terminate"}));
        let passthrough = gateway(json!({"mode": "Passthrough"}));
        assert_eq!(
            review(kinds::GATEWAY, Some(&terminate), Some(&passthrough)).as_deref(),
            Some("Gateway TLS")
        );
        let none = gateway(Value::Null);
        assert_eq!(review(kinds::GATEWAY, Some(&none), Some(&none)), None);
        assert_eq!(review(kinds::DEPLOYMENT, None, None), None);
        let cilium = GroupKind::new("cilium.io", "CiliumNetworkPolicy");
        assert_eq!(
            review(cilium, None, None).as_deref(),
            Some("CiliumNetworkPolicy")
        );
    }

    /// A kind of a sensitive name in another group is reviewed like any
    /// other object.
    #[test]
    fn a_custom_kind_of_a_sensitive_name_is_not_sensitive() {
        assert_eq!(
            review(GroupKind::new("example.com", "Secret"), None, None),
            None
        );
        assert_eq!(review(kinds::SECRET, None, None).as_deref(), Some("Secret"));
    }

    #[test]
    fn a_directory_loads_without_kix_annotations_or_records() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("shop")).unwrap();
        std::fs::write(
            dir.path().join("shop/Deployment-web.yaml"),
            format!(
                "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\n  namespace: shop\n  annotations:\n    {}: web\n    {}: abc\n",
                keys::PACKAGE,
                keys::IDENTITY_HASH
            ),
        )
        .unwrap();
        std::fs::write(
            dir.path().join("shop/PackageInstance-web.yaml"),
            "kind: PackageInstance\nmetadata:\n  name: web\n  namespace: shop\n",
        )
        .unwrap();
        std::fs::write(dir.path().join("README.md"), "not a manifest").unwrap();
        let got = load_dir(dir.path()).unwrap();
        assert_eq!(got.len(), 1);
        let web = &got["Deployment.apps/web@shop"];
        assert_eq!(web.package.as_deref(), Some("web"));
        assert!(web.manifest["metadata"].get("annotations").is_none());
    }
}
