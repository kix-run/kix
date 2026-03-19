#!/usr/bin/env python3
"""Build deploy graph and compute deployment waves from the Nix store DAG.

Reads the Nix store DAG via exportReferencesGraph,
filters for k8s resource store paths, and produces graph.json + waves.json.

Usage: graph.py <closure-graph-file> <activation-path> <output-dir>
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


def compute_waves(nodes, edges):
    """Compute deployment waves via topological sort.

    Wave 0 = resources with no dependencies.
    Wave N+1 = resources whose deps are all in waves 0..N.
    Cycles are dumped into the final wave.
    """
    node_ids = {n["id"] for n in nodes}
    node_map = {n["id"]: n for n in nodes}

    deps_of = {nid: set() for nid in node_ids}
    for edge in edges:
        if edge["from"] in deps_of:
            deps_of[edge["from"]].add(edge["to"])

    placed = set()
    remaining = set(node_ids)
    waves = []
    wave_idx = 0

    while remaining:
        ready = {nid for nid in remaining if deps_of[nid] <= placed}
        if not ready:
            waves.append({
                "wave": wave_idx,
                "resources": [node_map[nid] for nid in sorted(remaining)],
            })
            break
        waves.append({
            "wave": wave_idx,
            "resources": [node_map[nid] for nid in sorted(ready)],
        })
        placed |= ready
        remaining -= ready
        wave_idx += 1

    return waves


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <closure-graph-file> <activation-path> <output-dir>", file=sys.stderr)
        sys.exit(1)

    closure_file_path = sys.argv[1]
    activation_path = sys.argv[2]
    output_dir = sys.argv[3]

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
            "storePath": path,
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

    graph = {"nodes": nodes, "edges": edges}
    waves = compute_waves(nodes, edges)

    with open(os.path.join(output_dir, "graph.json"), "w") as f:
        json.dump(graph, f, indent=2)

    with open(os.path.join(output_dir, "waves.json"), "w") as f:
        json.dump(waves, f, indent=2)


if __name__ == "__main__":
    main()
