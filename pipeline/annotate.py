#!/usr/bin/env python3
"""Annotate kix manifests with identity-hash, content-hash, and depends-on.

Reads the Nix store DAG via exportReferencesGraph,
filters for k8s resource store paths, and produces annotated YAML files.

Usage: annotate.py <closure-graph-file> <activation-path> <output-dir> [--by-namespace]
"""

import hashlib
import json
import os
import sys

import yaml

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
    name_part = basename[33:]  # k8s-<Kind>-<ns>-<name>
    parts = name_part.split("-", 2)
    if len(parts) >= 2:
        return parts[1]
    return None


def main():
    if len(sys.argv) < 4:
        print(
            f"Usage: {sys.argv[0]} <closure-graph-file> <activation-path> <output-dir> [--by-namespace]",
            file=sys.stderr,
        )
        sys.exit(1)

    closure_file_path = sys.argv[1]
    activation_path = sys.argv[2]
    output_dir = sys.argv[3]
    by_namespace = "--by-namespace" in sys.argv

    os.makedirs(output_dir, exist_ok=True)

    closure = parse_closure_file(closure_file_path)

    # Filter to k8s resource paths, excluding the Activation CRD itself
    k8s_entries = []
    for entry in closure:
        path = entry["path"]
        if not is_k8s_path(path):
            continue
        kind = extract_kind_from_path(path)
        if kind == "Activation":
            continue
        k8s_entries.append(entry)

    # Set of all k8s paths for filtering references
    k8s_paths = {entry["path"] for entry in k8s_entries}

    for entry in k8s_entries:
        path = entry["path"]

        # Read the manifest JSON from the store path
        with open(path) as f:
            content = f.read()

        manifest = json.loads(content)

        # Compute annotations
        identity_hash = extract_identity_hash(path)
        content_hash = hashlib.sha256(content.encode()).hexdigest()

        # Find k8s dependencies from references
        refs = entry.get("references", [])
        dep_hashes = []
        for ref in refs:
            if ref in k8s_paths and ref != path:  # exclude self-reference
                dep_hashes.append(extract_identity_hash(ref))

        # Add kix annotations
        annotations = manifest.setdefault("metadata", {}).setdefault("annotations", {})
        annotations["kix.dev/identity-hash"] = identity_hash
        annotations["kix.dev/content-hash"] = content_hash
        if dep_hashes:
            annotations["kix.dev/depends-on"] = ",".join(sorted(dep_hashes))

        # Determine output filename
        kind = manifest.get("kind", "resource").lower()
        name = manifest.get("metadata", {}).get("name", "unnamed")
        ns = manifest.get("metadata", {}).get("namespace", "_cluster")

        if by_namespace:
            ns_dir = os.path.join(output_dir, ns)
            os.makedirs(ns_dir, exist_ok=True)
            filename = f"{name}-{kind}.yaml"
            output_path = os.path.join(ns_dir, filename)
        else:
            filename = f"{ns}--{name}-{kind}.yaml"
            output_path = os.path.join(output_dir, filename)

        with open(output_path, "w") as f:
            yaml.dump(manifest, f, default_flow_style=False, allow_unicode=True)


if __name__ == "__main__":
    main()
