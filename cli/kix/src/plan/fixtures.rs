//! Graphs for tests of package diffs: a small `web` package, its record,
//! and helpers to compare two lists of manifests as a build and a cluster.

use serde_json::{Value, json};

use super::{PackageDiff, diff_graphs};
use crate::eval::store_graph::StoreGraph;
use crate::manifest::keys;

/// An object of package `pkg` (`namespace`, `name`) with the stamps a
/// build writes.
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
                keys::DEPENDS_ON: "",
            }
        },
        "spec": spec,
    })
}

pub fn package_instance(ns: &str, name: &str, version: &str, hash: &str) -> Value {
    json!({
        "apiVersion": keys::API_VERSION,
        "kind": crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND,
        "metadata": {
            "name": name,
            "namespace": ns,
            "annotations": {keys::IDENTITY_HASH: hash}
        },
        "spec": {"instanceName": name, "namespaceName": ns, "version": version},
    })
}

pub fn cluster_level(kind: &str, name: &str, hash: &str, spec: Value) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": kind,
        "metadata": {"name": name, "annotations": {keys::IDENTITY_HASH: hash}},
        "spec": spec,
    })
}

pub fn record(name: &str, hash: &str) -> Value {
    json!({
        "apiVersion": keys::API_VERSION,
        "kind": crate::manifest::lifecycle::RECORD_KIND,
        "metadata": {"name": name, "annotations": {keys::IDENTITY_HASH: hash}},
        "spec": {"cluster": "c"},
    })
}

/// A 32-character identity hash made from `seed`.
pub fn h(seed: &str) -> String {
    format!("{seed:a<32}")
}

/// New side is a build; old side is whatever the cluster (or a
/// snapshot) said, synthesized against that build.
pub fn diff_of(old: &[Value], new: &[Value]) -> PackageDiff {
    let (old_graph, new_graph) = graphs_of(old, new);
    diff_graphs(&old_graph, &new_graph)
}

/// The old and new graphs [`diff_of`] compares.
pub fn graphs_of(old: &[Value], new: &[Value]) -> (StoreGraph, StoreGraph) {
    let new_graph = StoreGraph::synthesize(new, &StoreGraph::empty("c"));
    let old_graph = StoreGraph::synthesize(old, &new_graph);
    (old_graph, new_graph)
}

/// The record, the `app` Namespace, and package `app/web` with a
/// ConfigMap and a Deployment.
pub fn baseline() -> Vec<Value> {
    vec![
        record("c-old", &h("rec1")),
        cluster_level("Namespace", "app", &h("ns"), json!({})),
        package_instance("app", "web", "1.0.0", &h("pi")),
        stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm"),
            json!({"k": "v"}),
        ),
        stamped(
            "Deployment",
            "app",
            "web",
            ("app", "web"),
            &h("dep"),
            json!({"replicas": 2}),
        ),
    ]
}

pub fn crd(name: &str, pkg: (&str, &str), hash: &str) -> Value {
    json!({
        "apiVersion": "apiextensions.k8s.io/v1",
        "kind": "CustomResourceDefinition",
        "metadata": {
            "name": name,
            "annotations": {
                keys::PACKAGE: pkg.1,
                keys::PACKAGE_NAMESPACE: pkg.0,
                keys::IDENTITY_HASH: hash,
                keys::DEPENDS_ON: "",
            }
        },
        "spec": {},
    })
}

/// An object of package `app/web` with `fields` in place of `spec`.
pub fn web_resource(kind: &str, hash: &str, fields: Value) -> Value {
    let mut v = stamped(kind, "app", "web", ("app", "web"), hash, json!(null));
    let map = v.as_object_mut().unwrap();
    map.remove("spec");
    for (k, field) in fields.as_object().unwrap() {
        map.insert(k.clone(), field.clone());
    }
    v
}
