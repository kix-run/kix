//! Store graphs and manifests for tests, shared with `kix-lib`'s tests
//! through the `test-util` feature.

use std::collections::HashMap;
use std::path::PathBuf;

use serde_json::{Value, json};

use crate::eval::manifest_json::parse_index;
use crate::eval::store_graph::{PackageNode, ResourceNode, StoreGraph};
use crate::manifest::keys;

/// The `kix-enterprise-test` build as stored, for tests that need its bytes.
pub const KIX_ENTERPRISE_TEST_JSON: &[u8] =
    include_bytes!("../../tests/fixtures/kix-enterprise-test.json");

/// Load and validate the `kix-enterprise-test` fixture graph (26 manifests).
pub fn kix_enterprise_test() -> StoreGraph {
    #[derive(serde::Deserialize)]
    struct File {
        text: String,
        references: Vec<PathBuf>,
    }
    #[derive(serde::Deserialize)]
    struct Build {
        record: PathBuf,
        index: PathBuf,
        files: HashMap<PathBuf, File>,
    }
    let build: Build = serde_json::from_str(include_str!(
        "../../tests/fixtures/kix-enterprise-test.json"
    ))
    .unwrap();
    let index = parse_index("index", build.files[&build.index].text.as_bytes()).unwrap();
    let ref_cache = build
        .files
        .iter()
        .filter(|(_, f)| !f.references.is_empty())
        .map(|(path, f)| (path.clone(), f.references.clone()))
        .collect();
    let graph = StoreGraph::assemble(
        index,
        build.record,
        PathBuf::from("fixture:kix-enterprise-test"),
        ref_cache,
        &mut |path| Ok(build.files[path].text.clone().into_bytes()),
        &|_| {},
    )
    .unwrap();
    graph.validate().unwrap();
    graph
}

/// Build a stamped manifest matching the shape produced by a build or
/// the Kix-owned view of a live object.
pub fn stamped(
    kind: &str,
    ns: &str,
    name: &str,
    pkg: (&str, &str),
    hash: &str,
    spec: Value,
) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": kind,
        "metadata": {
            "name": name,
            "namespace": ns,
            "annotations": {
                keys::PACKAGE: pkg.1,
                keys::PACKAGE_NAMESPACE: pkg.0,
                keys::IDENTITY_HASH: hash,
            }
        },
        "spec": spec,
    })
}

/// Format a 32-character store hash from `seed`.
pub fn h(seed: &str) -> String {
    format!("{seed:a<32}")
}

pub fn pkg<'a>(g: &'a StoreGraph, ns: &str, name: &str) -> &'a PackageNode {
    g.packages
        .values()
        .find(|p| p.namespace == ns && p.instance_name == name)
        .unwrap_or_else(|| panic!("no package {ns}/{name}"))
}

/// Build an unstamped `PackageInstance` manifest as rendered by the Nix
/// library, optionally configured as an import marker (`secret-ref-*`,
/// `service-ref-*`, or `platform-*`).
pub fn rendered_pi(ns: &str, name: &str, import: Option<(&str, &str)>) -> Value {
    let mut anns = serde_json::Map::new();
    anns.insert(keys::DEPENDS_ON.into(), json!("x,requires:y"));
    if let Some((kind, target)) = import {
        anns.insert(keys::MODE.into(), json!("import"));
        anns.insert(keys::IMPORT_API_VERSION.into(), json!("v1"));
        anns.insert(keys::IMPORT_KIND.into(), json!(kind));
        anns.insert(keys::IMPORT_NAME.into(), json!(target));
    }
    let mut spec = json!({"instanceName": name, "namespaceName": ns});
    if import.is_some() {
        spec["mode"] = json!("import");
    } else {
        spec["version"] = json!("1");
    }
    json!({
        "apiVersion": keys::API_VERSION,
        "kind": crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND,
        "metadata": {
            "name": name,
            "namespace": ns,
            "annotations": anns,
            "labels": {"app.kubernetes.io/instance": name},
        },
        "spec": spec,
    })
}

pub fn rendered(kind: &str, ns: &str, name: &str) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": kind,
        "metadata": {"name": name, "namespace": ns},
    })
}

/// `(store hash seed, PackageInstance, [(seed, resource)])`.
pub type BuiltPackage<'a> = (&'a str, Value, Vec<(&'a str, Value)>);

/// Build a stamped `StoreGraph` from `packages`, sharing store paths for
/// identical seeds across packages.
pub fn built(packages: &[BuiltPackage]) -> StoreGraph {
    let path = |seed: &str| PathBuf::from(format!("/nix/store/{}-k8s", h(seed)));
    let mut g = StoreGraph::empty("c");
    for (pi_seed, pi, resources) in packages {
        let pi_path = path(pi_seed);
        g.resources.insert(
            pi_path.clone(),
            ResourceNode {
                store_path: pi_path.clone(),
                manifest: pi.clone(),
            },
        );
        let mut resource_paths = Vec::new();
        for (seed, manifest) in resources {
            let p = path(seed);
            g.resources.insert(
                p.clone(),
                ResourceNode {
                    store_path: p.clone(),
                    manifest: manifest.clone(),
                },
            );
            g.resource_owner.insert(p.clone(), pi_path.clone());
            resource_paths.push(p);
        }
        g.packages.insert(
            pi_path.clone(),
            PackageNode {
                store_path: pi_path,
                instance_name: pi["spec"]["instanceName"].as_str().unwrap().into(),
                namespace: pi["metadata"]["namespace"].as_str().unwrap().into(),
                version: pi["spec"]["version"].as_str().map(str::to_string),
                lifecycle: None,
                resource_paths,
                cross_deps: vec![],
            },
        );
    }
    crate::eval::stamp::stamp_annotations(&mut g);
    g
}

/// Return the live side as a failed deploy leaves it: every manifest of
/// `build`, with each import marker's identity hash moved and its
/// `kix.run/package` stamp replaced by `stamp`.
pub fn after_failed_deploy(build: &StoreGraph, stamp: &str) -> Vec<Value> {
    build
        .resources
        .values()
        .map(|n| {
            let mut m = n.manifest.clone();
            if crate::manifest::lifecycle::is_marker(&m) {
                let anns = &mut m["metadata"]["annotations"];
                anns[keys::IDENTITY_HASH] = json!(h("moved"));
                anns[keys::PACKAGE] = json!(stamp);
            }
            m
        })
        .collect()
}

/// Return the names of the resources `g` lists under package `ns/name`.
pub fn names_in(g: &StoreGraph, ns: &str, name: &str) -> Vec<String> {
    let mut names: Vec<String> = pkg(g, ns, name)
        .resource_paths
        .iter()
        .map(|p| {
            g.resources[p].manifest["metadata"]["name"]
                .as_str()
                .unwrap()
                .into()
        })
        .collect();
    names.sort();
    names
}
