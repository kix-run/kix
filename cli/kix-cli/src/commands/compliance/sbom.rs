//! CycloneDX 1.6 SBOM generation from a StoreGraph.
//!
//! Walks the built StoreGraph and extracts:
//!
//! - The cluster itself as `metadata.component` (type `platform`)
//! - Each package as an `application` component (purl `pkg:kix/<name>@<version>`)
//! - Each unique container image as a `container` component
//!   (purl `pkg:docker/<org>/<image>@<tag>`)
//! - Each Nix flake input as a `library` component (purl `pkg:nix/<name>@<rev>`)
//! - A `dependencies` graph derived from `StoreGraph::cross_deps`
//!
//! All inputs are available at build time without invoking a scanner.

use std::collections::BTreeMap;

use miette::Result;
use serde_json::{Value, json};

use kix::eval::store_graph::{PackageNode, StoreGraph};

use crate::cli::ComplianceSbomArgs;
use crate::output;

use super::shared;
use crate::commands::CommandContext;
use kix::manifest::keys;

pub fn run(args: &ComplianceSbomArgs, ctx: &mut CommandContext) -> Result<()> {
    let graph = shared::build_and_load(ctx, &args.cluster)?;
    let sbom = build_sbom(&graph, &ctx.global.flake);

    output::result(&output::Standard(sbom))
}

pub fn build_sbom(graph: &StoreGraph, flake_ref: &str) -> Value {
    let activation_hash = shared::activation_identity_hash(graph);
    let cluster_bom_ref = format!("cluster-{}", graph.cluster_name);

    let mut components: Vec<Value> = Vec::new();
    // Package bom-ref for dependency edges is built from the instance store
    // hash to stay stable across packages with the same instance name in
    // different namespaces.
    let pkg_bomref = |p: &PackageNode| -> String {
        format!(
            "pkg-{}-{}",
            p.namespace,
            kix::eval::store_graph::store_hash(&p.store_path)
        )
    };

    for pkg in graph.packages.values() {
        let version = pkg.version.clone().unwrap_or_else(|| "unknown".into());
        let purl = format!(
            "pkg:kix/{}/{}@{}",
            pkg.namespace, pkg.instance_name, version
        );
        let mut props = vec![
            prop("kix:namespace", &pkg.namespace),
            prop(
                "kix:identity-hash",
                &kix::eval::store_graph::store_hash(&pkg.store_path),
            ),
        ];
        if let Some(lifecycle) = &pkg.lifecycle {
            props.push(prop("kix:lifecycle", lifecycle));
        }
        components.push(json!({
            "type": "application",
            "bom-ref": pkg_bomref(pkg),
            "name": pkg.instance_name,
            "version": version,
            "purl": purl,
            "properties": props,
        }));
    }

    // Map each unique container image reference to `Vec<(owning_pkg_bomref, container_name)>`.
    let mut image_refs: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
    for pkg in graph.packages.values() {
        let bomref = pkg_bomref(pkg);
        for res_path in &pkg.resource_paths {
            let Some(node) = graph.resources.get(res_path) else {
                continue;
            };
            collect_images(&node.manifest, &bomref, &mut image_refs);
        }
    }

    let mut image_bomrefs: BTreeMap<String, String> = BTreeMap::new();
    for image in image_refs.keys() {
        let (name, version, digest) = parse_docker_ref(image);
        let bom_ref = format!("image-{}", sanitize(image));
        image_bomrefs.insert(image.clone(), bom_ref.clone());
        let purl = docker_purl(&name, &version);
        let mut comp = json!({
            "type": "container",
            "bom-ref": bom_ref,
            "name": name,
            "version": version,
            "purl": purl,
        });
        if let Some(d) = digest {
            comp["hashes"] = json!([{ "alg": "SHA-256", "content": d }]);
        }
        components.push(comp);
    }

    let flake_path = crate::commands::resolve_flake_path(flake_ref).ok();
    let mut flake_input_bomrefs: Vec<String> = Vec::new();
    if let Some(path) = &flake_path
        && let Some(lock) = shared::read_flake_lock(path)
    {
        for (name, locked) in kix::flake_lock::locked_inputs(&lock) {
            let rev = locked
                .get("rev")
                .or_else(|| locked.get("narHash"))
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            let purl = format!("pkg:nix/{name}@{rev}");
            let bom_ref = format!("nix-{}", sanitize(name));
            flake_input_bomrefs.push(bom_ref.clone());
            components.push(json!({
                "type": "library",
                "bom-ref": bom_ref,
                "name": name,
                "version": rev,
                "purl": purl,
                "properties": [
                    prop("kix:source", "flake.lock"),
                    prop(
                        "kix:locked",
                        &serde_json::to_string(locked).unwrap_or_default(),
                    )
                ],
            }));
        }
    }

    let mut dep_edges: Vec<Value> = Vec::new();
    for pkg in graph.packages.values() {
        let bomref = pkg_bomref(pkg);
        let mut deps: Vec<String> = Vec::new();

        for cd in &pkg.cross_deps {
            if let Some(target) = graph.packages.get(&cd.target_package) {
                deps.push(pkg_bomref(target));
            }
        }
        deps.sort();
        deps.dedup();

        let mut pkg_images: Vec<String> = image_refs
            .iter()
            .filter(|(_, users)| users.iter().any(|(r, _)| r == &bomref))
            .filter_map(|(image, _)| image_bomrefs.get(image).cloned())
            .collect();
        pkg_images.sort();
        pkg_images.dedup();
        deps.extend(pkg_images);

        dep_edges.push(json!({
            "ref": bomref,
            "dependsOn": deps,
        }));
    }
    // Cluster depends on every package + flake input.
    let mut cluster_deps: Vec<String> = graph.packages.values().map(pkg_bomref).collect();
    cluster_deps.extend(flake_input_bomrefs);
    dep_edges.push(json!({
        "ref": cluster_bom_ref,
        "dependsOn": cluster_deps,
    }));

    json!({
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "version": 1,
        "serialNumber": format!("urn:uuid:{}", shared::new_uuid()),
        "metadata": {
            "timestamp": shared::now_rfc3339(),
            "tools": {
                "components": [{
                    "type": "application",
                    "name": "kix",
                    "version": kix::version::running().to_string(),
                    "vendor": keys::DOMAIN,
                }]
            },
            "component": {
                "type": "platform",
                "bom-ref": cluster_bom_ref,
                "name": format!("cluster-{}", graph.cluster_name),
                "version": format!("activation-{activation_hash}"),
                "description": format!("kix cluster {}", graph.cluster_name),
                "properties": [
                    prop("kix:activation-hash", &activation_hash),
                    prop("kix:flake-ref", flake_ref),
                ],
            }
        },
        "components": components,
        "dependencies": dep_edges,
    })
}

fn prop(name: &str, value: &str) -> Value {
    json!({ "name": name, "value": value })
}

fn sanitize(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '.' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

/// Walk a manifest looking for `spec.template.spec.containers[].image` and
/// variants, recording each image against the owning-package bom-ref.
fn collect_images(
    manifest: &Value,
    owner_bomref: &str,
    out: &mut BTreeMap<String, Vec<(String, String)>>,
) {
    if let Some(spec) = kix::manifest::workload::pod_spec(manifest) {
        for field in ["containers", "initContainers", "ephemeralContainers"] {
            let Some(arr) = spec.get(field).and_then(|v| v.as_array()) else {
                continue;
            };
            for c in arr {
                let Some(image) = c.get("image").and_then(|v| v.as_str()) else {
                    continue;
                };
                let name = c
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("<unnamed>")
                    .to_string();
                out.entry(image.to_string())
                    .or_default()
                    .push((owner_bomref.to_string(), name));
            }
        }
    }
}

/// Parse a Docker image reference into (name, version/tag, optional digest).
///
/// Examples:
///   "ghcr.io/immich-app/immich-server:v1.99.0"   → ("ghcr.io/immich-app/immich-server", "v1.99.0", None)
///   "nginx@sha256:abc..."                        → ("nginx", "latest", Some("abc..."))
///   "nginx:1.25@sha256:abc..."                   → ("nginx", "1.25", Some("abc..."))
fn parse_docker_ref(image: &str) -> (String, String, Option<String>) {
    let (without_digest, digest) = match image.split_once('@') {
        Some((prefix, digest)) => {
            let d = digest.strip_prefix("sha256:").unwrap_or(digest).to_string();
            (prefix, Some(d))
        }
        None => (image, None),
    };

    // Split on the last ':' that is NOT part of a host:port.
    // Simple heuristic: if the part after the last '/' contains ':', that's the tag.
    let (name, tag) = if let Some(slash) = without_digest.rfind('/') {
        let (host, last) = without_digest.split_at(slash + 1);
        if let Some((img, tag)) = last.split_once(':') {
            (format!("{host}{img}"), tag.to_string())
        } else {
            (without_digest.to_string(), "latest".to_string())
        }
    } else if let Some((img, tag)) = without_digest.split_once(':') {
        (img.to_string(), tag.to_string())
    } else {
        (without_digest.to_string(), "latest".to_string())
    };

    (name, tag, digest)
}

/// Build a CycloneDX `pkg:docker/...` purl.
fn docker_purl(name: &str, version: &str) -> String {
    // purl spec: pkg:docker/<namespace>/<name>@<version>?repository_url=<host>
    if let Some(slash) = name.find('/') {
        let (host_or_ns, rest) = name.split_at(slash);
        let rest = &rest[1..];
        if host_or_ns.contains('.') || host_or_ns.contains(':') {
            // Has a registry host
            return format!("pkg:docker/{rest}@{version}?repository_url={host_or_ns}");
        }
    }
    format!("pkg:docker/{name}@{version}")
}
