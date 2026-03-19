#!/usr/bin/env python3
"""Build deploy graph from the Nix store DAG.

Reads the store DAG via exportReferencesGraph, cross-references with
the annotated manifests directory, and produces graph.json.

Usage: graph.py <closure-graph-file> <activation-path> <manifests-dir> <output-dir>
"""

import json
import os
import sys

from closure import parse_closure_file


def is_k8s_path(path):
    """Check if a store path is a kix k8s resource (named k8s-*)."""
    basename = os.path.basename(path)
    name_part = basename[33:]  # skip hash + dash
    return name_part.startswith("k8s-")


def extract_identity_hash(path):
    """Extract the 32-char base32 hash from a Nix store path."""
    return os.path.basename(path)[:32]


def extract_kind_from_path(path):
    """Extract the kind from a k8s store path name."""
    basename = os.path.basename(path)
    name_part = basename[33:]
    parts = name_part.split("-", 2)
    if len(parts) >= 2:
        return parts[1]
    return None


def build_manifest_filename(manifest):
    """Build the YAML filename matching annotate.py's naming convention."""
    kind = manifest.get("kind", "resource").lower()
    name = manifest.get("metadata", {}).get("name", "unnamed")
    ns = manifest.get("metadata", {}).get("namespace", "_cluster")
    return f"{ns}--{name}-{kind}.yaml"


def main():
    if len(sys.argv) != 5:
        print(f"Usage: {sys.argv[0]} <closure-graph-file> <activation-path> <manifests-dir> <output-dir>", file=sys.stderr)
        sys.exit(1)

    closure_file_path = sys.argv[1]
    activation_path = sys.argv[2]
    manifests_dir = sys.argv[3]
    output_dir = sys.argv[4]

    os.makedirs(output_dir, exist_ok=True)

    closure = parse_closure_file(closure_file_path)

    # Filter to k8s paths, excluding Activation
    k8s_entries = []
    for entry in closure:
        path = entry["path"]
        if not is_k8s_path(path):
            continue
        kind = extract_kind_from_path(path)
        if kind == "Activation":
            continue
        k8s_entries.append(entry)

    k8s_paths = {entry["path"] for entry in k8s_entries}

    # Build a map from store path → manifest filename
    path_to_filename = {}
    for entry in k8s_entries:
        with open(entry["path"]) as f:
            manifest = json.load(f)
        path_to_filename[entry["path"]] = build_manifest_filename(manifest)

    # Build graph nodes and edges
    nodes = []
    edges = []

    for entry in k8s_entries:
        path = entry["path"]

        with open(path) as f:
            manifest = json.load(f)

        kind = manifest.get("kind", "")
        api_version = manifest.get("apiVersion", "")
        name = manifest.get("metadata", {}).get("name", "")
        namespace = manifest.get("metadata", {}).get("namespace")
        ns_key = namespace if namespace else "_cluster_"
        resource_id = f"{kind}/{name}@{ns_key}"

        nodes.append({
            "id": resource_id,
            "apiVersion": api_version,
            "kind": kind,
            "name": name,
            "namespace": namespace,
            "file": path_to_filename[path],
            "identityHash": extract_identity_hash(path),
        })

        # Edges from references
        refs = entry.get("references", [])
        for ref in refs:
            if ref in k8s_paths and ref != path:
                with open(ref) as f:
                    dep_manifest = json.load(f)
                dep_kind = dep_manifest.get("kind", "")
                dep_name = dep_manifest.get("metadata", {}).get("name", "")
                dep_ns = dep_manifest.get("metadata", {}).get("namespace")
                dep_ns_key = dep_ns if dep_ns else "_cluster_"
                dep_id = f"{dep_kind}/{dep_name}@{dep_ns_key}"
                edges.append({"from": resource_id, "to": dep_id})

    graph = {
        "manifests": manifests_dir,
        "nodes": nodes,
        "edges": edges,
    }

    with open(os.path.join(output_dir, "graph.json"), "w") as f:
        json.dump(graph, f, indent=2)


if __name__ == "__main__":
    main()
