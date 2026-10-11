//! Graphs for tests: a small `web` package, its record, helpers to compare
//! two lists of manifests as a build and a cluster, and a real build.

use std::collections::HashMap;
use std::path::PathBuf;

use serde_json::{Value, json};

use super::baseline::{ActiveSource, Baseline};
use super::document::{PlanFlags, PruneModeFlag};
use super::{CheckedPlan, PackageDiff, PlanError, Planner, diff_graphs};
use crate::cluster::scheduler::PrunePolicy;
use crate::eval::manifest_json::parse_index;
use crate::eval::stamp::stamp_annotations;
use crate::eval::store_graph::StoreGraph;
use crate::manifest::keys;
use crate::manifest::types::ResourceId;

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

/// The `kix-enterprise-test` build, a real build of 26 manifests on stage1, as
/// [`StoreGraph::assemble`] reads it and [`StoreGraph::validate`] accepts
/// it. The fixture holds each store file's text and references;
/// `kix-bundle` checks that its bundle of the same build reads as this
/// graph.
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

/// The planning flags `extra` sets, as `kix deploy` parses them.
pub fn flags(extra: &[&str]) -> PlanFlags {
    let mut flags = PlanFlags {
        prune: false,
        prune_mode: None,
        reconcile: false,
        force_conflicts: false,
        accept_migrations: false,
    };
    let mut args = extra.iter();
    while let Some(arg) = args.next() {
        match *arg {
            "--prune" => flags.prune = true,
            "--reconcile" => flags.reconcile = true,
            "--force-conflicts" => flags.force_conflicts = true,
            "--accept-migrations" => flags.accept_migrations = true,
            "--prune-mode" => {
                flags.prune_mode = match args.next().copied() {
                    Some("default") => Some(PruneModeFlag::Default),
                    Some("no") => Some(PruneModeFlag::No),
                    other => panic!("--prune-mode {other:?}"),
                }
            }
            other => panic!("not a planning flag: {other}"),
        }
    }
    flags
}

/// The baseline of a cluster that runs `old`, or nothing.
pub fn deployed(old: Option<&StoreGraph>) -> Baseline {
    match old {
        Some(old) => {
            let (graph, manifests) = stamp(old);
            Baseline {
                source: ActiveSource::Build(Box::new(graph)),
                active_manifests: manifests,
                ..Baseline::empty()
            }
        }
        None => Baseline::empty(),
    }
}

/// [`Planner::plan`] for a deploy of `new` over `baseline` with `flags`,
/// before the plan reads the cluster.
pub fn plan(
    baseline: &Baseline,
    new: &StoreGraph,
    flags: PlanFlags,
) -> Result<CheckedPlan, PlanError> {
    let (new_graph, _) = stamp(new);
    let planner = Planner::new(flags, &|_| {});
    futures::executor::block_on(planner.plan(&new_graph, &new.cluster_name, baseline, None))
}

pub fn stamp(graph: &StoreGraph) -> (StoreGraph, Vec<Value>) {
    let mut graph = graph.clone();
    stamp_annotations(&mut graph);
    let manifests = graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect();
    (graph, manifests)
}

/// The baseline of a cluster whose Active objects are `manifests`, its
/// build not on this machine.
pub fn deployed_objects(manifests: Vec<Value>) -> Baseline {
    Baseline {
        source: ActiveSource::Live,
        active_manifests: manifests,
        ..Baseline::empty()
    }
}

/// What a deploy with `prune` deletes of the plan's `orphans`.
pub fn deletes_of(prune: PrunePolicy, orphans: &[ResourceId]) -> Vec<ResourceId> {
    super::planner::deletes_of(prune, orphans)
}

/// Whether the field at `path` set to `value` is the same as unset.
pub fn equivalent_to_unset(path: &str, value: &Value) -> bool {
    crate::manifest::diff::equivalence::equivalent_to_unset(path, value)
}

/// The old side a plan over `baseline` compares `new` with, and the Active
/// record's manifests.
pub fn old_side<'a>(baseline: &'a Baseline, new: &StoreGraph) -> (StoreGraph, &'a [Value]) {
    (
        baseline.diff_side(new).into_owned(),
        &baseline.active_manifests,
    )
}

/// What `--detail manifests` shows for `manifest`, written over `old`.
pub fn shown_manifest(manifest: &Value, old: Option<&Value>) -> Value {
    let is_secret = crate::manifest::types::is_secret(manifest)
        || old.is_some_and(crate::manifest::types::is_secret);
    super::shown_value(
        is_secret,
        "$",
        manifest,
        old,
        super::MAX_SHOWN_MANIFEST_BYTES,
    )
}

/// The Nix store directory store paths are made in.
pub const STORE_DIR: &str = crate::eval::store_path::STORE_DIR;
/// The kind of a package's PackageInstance.
pub const PACKAGE_INSTANCE_KIND: &str = crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND;
/// The `kix.run/rerun` annotation key.
pub const RERUN: &str = crate::manifest::keys::RERUN;
/// The `kix.run/sops-source` annotation key.
pub const SOPS_SOURCE: &str = crate::manifest::keys::SOPS_SOURCE;

/// The retired spellings of the annotation key `key`.
pub fn legacy_spellings(key: &str) -> Vec<String> {
    crate::legacy_domain::legacy_spellings(key)
}
