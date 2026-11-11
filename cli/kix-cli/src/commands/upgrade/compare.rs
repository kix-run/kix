//! Compare a cluster's manifests before and after an upgrade, and say which
//! changes a change record explains and which touch access or encryption.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use kix::manifest::hash::strip_kix_annotations;
use kix::manifest::keys;
use kix::manifest::lifecycle::is_kix_internal_kind;
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
/// id. Kix's own records (Activation, PackageInstance) are left out.
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
            if is_kix_internal_kind(&id.kind) {
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

impl Change {
    pub fn word(self) -> &'static str {
        match self {
            Change::Added => "added",
            Change::Removed => "removed",
            Change::Changed => "changed",
        }
    }
}

/// One object that differs after the upgrade.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct ObjectChange {
    pub id: String,
    pub change: Change,
    pub package: Option<String>,
    /// A change record names the object's package.
    pub explained: bool,
    /// The object controls access, network reach, or encryption.
    pub sensitive: bool,
}

/// The kinds whose every change a person should read.
const SENSITIVE_KINDS: &[&str] = &[
    "Secret",
    "Role",
    "ClusterRole",
    "RoleBinding",
    "ClusterRoleBinding",
    "NetworkPolicy",
    "CiliumNetworkPolicy",
    "CiliumClusterwideNetworkPolicy",
    "Certificate",
];

/// Return the TLS settings of an Ingress or a Gateway.
fn tls(manifest: &Value) -> Value {
    match manifest["kind"].as_str() {
        Some("Ingress") => manifest["spec"]["tls"].clone(),
        Some("Gateway") => Value::Array(
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

/// Return whether a change from `before` to `after` is sensitive.
pub fn sensitive(kind: &str, before: Option<&Value>, after: Option<&Value>) -> bool {
    if SENSITIVE_KINDS.contains(&kind) {
        return true;
    }
    if !matches!(kind, "Ingress" | "Gateway") {
        return false;
    }
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

/// Compare one cluster's objects. A change is explained when `explaining`
/// holds the object's package.
pub fn compare(
    before: &BTreeMap<String, Object>,
    after: &BTreeMap<String, Object>,
    explaining: &BTreeSet<String>,
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
        let kind = either.manifest["kind"].as_str().unwrap_or_default();
        out.push(ObjectChange {
            id: id.clone(),
            change,
            explained: package.as_ref().is_some_and(|p| explaining.contains(p)),
            sensitive: sensitive(kind, old.map(|o| &o.manifest), new.map(|n| &n.manifest)),
            package,
        });
    }
    out
}

/// Return a summary line per change kind, such as `2 added: a, b`, which two
/// clusters share when their changes are the same.
pub fn summary(changes: &[ObjectChange]) -> Vec<String> {
    let mut lines = Vec::new();
    for change in [Change::Added, Change::Removed, Change::Changed] {
        let ids: Vec<String> = changes
            .iter()
            .filter(|c| c.change == change)
            .map(|c| {
                let mut notes = Vec::new();
                if !c.explained {
                    notes.push("no change record");
                }
                if c.sensitive {
                    notes.push("sensitive");
                }
                if notes.is_empty() {
                    c.id.clone()
                } else {
                    format!("{} ({})", c.id, notes.join(", "))
                }
            })
            .collect();
        if !ids.is_empty() {
            lines.push(format!("{} {}:", ids.len(), change.word()));
            lines.extend(ids.into_iter().map(|id| format!("  {id}")));
        }
    }
    lines
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
                object("web", json!({"kind": "Secret"})),
            ),
            (
                "ConfigMap/same@shop".to_string(),
                object("db", json!({"kind": "ConfigMap"})),
            ),
        ]);
        let after = BTreeMap::from([
            (
                "Deployment/web@shop".to_string(),
                object("web", deployment("b")),
            ),
            (
                "ConfigMap/same@shop".to_string(),
                object("db", json!({"kind": "ConfigMap"})),
            ),
            (
                "ClusterRole/new".to_string(),
                object("db", json!({"kind": "ClusterRole"})),
            ),
        ]);
        let explaining = BTreeSet::from(["web".to_string()]);
        let got = compare(&before, &after, &explaining);
        let view: Vec<(&str, Change, bool, bool)> = got
            .iter()
            .map(|c| (c.id.as_str(), c.change, c.explained, c.sensitive))
            .collect();
        assert_eq!(
            view,
            [
                ("ClusterRole/new", Change::Added, false, true),
                ("Deployment/web@shop", Change::Changed, true, false),
                ("Secret/old@shop", Change::Removed, true, true),
            ]
        );
        assert_eq!(
            summary(&got),
            [
                "1 added:",
                "  ClusterRole/new (no change record, sensitive)",
                "1 removed:",
                "  Secret/old@shop (sensitive)",
                "1 changed:",
                "  Deployment/web@shop",
            ]
        );
    }

    #[test]
    fn an_ingress_or_gateway_is_sensitive_when_its_tls_changes() {
        let ingress = |tls: Value| json!({"kind": "Ingress", "spec": {"rules": [], "tls": tls}});
        let a = ingress(json!([{"secretName": "a"}]));
        let b = ingress(json!([{"secretName": "b"}]));
        assert!(sensitive("Ingress", Some(&a), Some(&b)));
        assert!(!sensitive("Ingress", Some(&a), Some(&a)));
        let plain = json!({"kind": "Ingress", "spec": {"rules": [1]}});
        assert!(!sensitive("Ingress", None, Some(&plain)));
        assert!(sensitive("Ingress", None, Some(&a)));

        let gateway = |tls: Value| json!({"kind": "Gateway", "spec": {"listeners": [{"name": "h", "tls": tls}]}});
        assert!(sensitive(
            "Gateway",
            Some(&gateway(json!({"mode": "Terminate"}))),
            Some(&gateway(json!({"mode": "Passthrough"})))
        ));
        assert!(!sensitive(
            "Gateway",
            Some(&gateway(Value::Null)),
            Some(&gateway(Value::Null))
        ));
        assert!(!sensitive("Deployment", None, None));
        assert!(sensitive("CiliumNetworkPolicy", None, None));
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
        let web = &got["Deployment/web@shop"];
        assert_eq!(web.package.as_deref(), Some("web"));
        assert!(web.manifest["metadata"].get("annotations").is_none());
    }
}
