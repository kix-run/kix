#!/usr/bin/env python3
"""
Normalize and compare Helm chart output vs kix module output.

Called by verify-parity.sh with these env vars:
  HELM_OUT  — directory containing rendered Helm YAML files
  KIX_OUT   — directory containing kix JSON files (from nix build)
  WORK_DIR  — scratch directory for normalized JSON

This script:
1. Reads Helm YAML, strips cosmetic Helm fields, writes normalized JSON
2. Reads kix JSON, strips cosmetic kix fields, writes normalized JSON
3. Matches resources by kind and compares them
"""

import yaml
import json
import os
import sys
import glob

helm_out = os.environ["HELM_OUT"]
kix_out = os.environ["KIX_OUT"]
work_dir = os.environ["WORK_DIR"]

helm_json_dir = os.path.join(work_dir, "helm-json")
kix_json_dir = os.path.join(work_dir, "kix-json")
os.makedirs(helm_json_dir, exist_ok=True)
os.makedirs(kix_json_dir, exist_ok=True)

# --- Cosmetic fields to strip ---
# These differ between Helm and kix but don't affect runtime behavior.

STRIP_LABELS = {"helm.sh/chart", "app.kubernetes.io/managed-by"}
STRIP_ANNOTATIONS = {
    "meta.helm.sh/release-name",
    "meta.helm.sh/release-namespace",
    "checksum/config",
}
KIX_ANNOTATION_PREFIXES = ["build.kix.dev/"]

# Helm prefixes resource names with the release name. Since kix doesn't use
# release names (resources are named after the app), we normalize Helm names
# by stripping the "release-name-" prefix so that name differences don't
# dominate the diff output.
HELM_RELEASE_PREFIX = "release-name-"


def strip_release_prefix(name):
    """Remove the Helm release name prefix from a resource name."""
    if isinstance(name, str) and name.startswith(HELM_RELEASE_PREFIX):
        return name[len(HELM_RELEASE_PREFIX):]
    return name


def normalize_names_recursive(obj):
    """Recursively strip release-name- prefix from all 'name' fields.

    Helm names resources as 'release-name-<app>' while kix just uses '<app>'.
    This normalizes Helm output so we can compare behavioral differences
    without noise from naming conventions.
    """
    if isinstance(obj, dict):
        result = {}
        for k, v in obj.items():
            if k in ("name", "serviceAccountName") and isinstance(v, str):
                result[k] = strip_release_prefix(v)
            else:
                result[k] = normalize_names_recursive(v)
        return result
    elif isinstance(obj, list):
        return [normalize_names_recursive(item) for item in obj]
    return obj


def normalize_helm(doc):
    """Strip Helm-specific cosmetic fields for behavioral comparison."""
    if not isinstance(doc, dict):
        return doc

    # Strip cosmetic labels from top-level metadata
    labels = doc.get("metadata", {}).get("labels", {})
    for key in STRIP_LABELS:
        labels.pop(key, None)

    # Strip cosmetic annotations from top-level metadata
    annotations = doc.get("metadata", {}).get("annotations", {})
    for key in STRIP_ANNOTATIONS:
        annotations.pop(key, None)
    if not annotations and "annotations" in doc.get("metadata", {}):
        del doc["metadata"]["annotations"]

    # Strip cosmetic annotations from pod template metadata too
    tmpl = doc.get("spec", {}).get("template", {}).get("metadata", {})
    for key in STRIP_ANNOTATIONS:
        tmpl.get("annotations", {}).pop(key, None)

    # Normalize release-name- prefix from all name fields
    doc = normalize_names_recursive(doc)

    # Sort ports arrays so ordering differences don't cause false diffs
    doc = sort_port_arrays(doc)

    return doc


def normalize_kix(doc):
    """Strip kix-specific cosmetic fields for behavioral comparison."""
    if not isinstance(doc, dict):
        return doc

    # Strip kix-specific annotations (build.kix.dev/*)
    annotations = doc.get("metadata", {}).get("annotations", {})
    for key in list(annotations.keys()):
        for prefix in KIX_ANNOTATION_PREFIXES:
            if key.startswith(prefix):
                del annotations[key]
                break
    if not annotations and "annotations" in doc.get("metadata", {}):
        del doc["metadata"]["annotations"]

    # Strip managed-by and helm.sh/chart labels (same as Helm side)
    labels = doc.get("metadata", {}).get("labels", {})
    for key in STRIP_LABELS:
        labels.pop(key, None)

    # Sort ports arrays so ordering differences don't cause false diffs
    doc = sort_port_arrays(doc)

    return doc


def sort_port_arrays(obj):
    """Sort ports arrays by (protocol, name) so ordering doesn't cause false diffs.

    Helm and kix may emit ports in different orders (e.g., UDP-53 then TCP-53 vs
    TCP-53 then UDP-53). The order doesn't matter to Kubernetes, so we normalize.
    """
    if isinstance(obj, dict):
        result = {}
        for k, v in obj.items():
            if k == "ports" and isinstance(v, list) and v and isinstance(v[0], dict):
                result[k] = sorted(v, key=lambda p: (p.get("name", ""), p.get("protocol", "")))
            else:
                result[k] = sort_port_arrays(v)
        return result
    elif isinstance(obj, list):
        return [sort_port_arrays(item) for item in obj]
    return obj


def resource_key(doc):
    """Generate a filename key from kind + name."""
    kind = doc.get("kind", "unknown").lower()
    name = doc.get("metadata", {}).get("name", "unknown")
    return f"{kind}-{name}"


# --- Step 1: Convert Helm YAML to normalized JSON ---
for yaml_file in glob.glob(os.path.join(helm_out, "**/*.yaml"), recursive=True):
    with open(yaml_file) as f:
        for i, doc in enumerate(yaml.safe_load_all(f)):
            if doc is None:
                continue
            doc = normalize_helm(doc)
            fname = resource_key(doc)
            if i > 0:
                fname += f"-{i}"
            with open(os.path.join(helm_json_dir, f"{fname}.json"), "w") as out:
                json.dump(doc, out, sort_keys=True, indent=2)

# --- Step 2: Normalize kix JSON ---
for json_file in glob.glob(os.path.join(kix_out, "*.json")):
    with open(json_file) as f:
        doc = json.load(f)
    doc = normalize_kix(doc)
    fname = resource_key(doc)
    with open(os.path.join(kix_json_dir, f"{fname}.json"), "w") as out:
        json.dump(doc, out, sort_keys=True, indent=2)

# --- Step 3: Compare ---
print()
print("=== Comparison ===")
print()

helm_files = {os.path.basename(f): f for f in glob.glob(os.path.join(helm_json_dir, "*.json"))}
kix_files = {os.path.basename(f): f for f in glob.glob(os.path.join(kix_json_dir, "*.json"))}

print(f"Helm resources: {len(helm_files)}")
print(f"Kix resources:  {len(kix_files)}")
print()

# Build index by kind for fuzzy matching (names may differ between Helm and kix)
def load_json(path):
    with open(path) as f:
        return json.load(f)

helm_by_kind = {}
for fname, path in helm_files.items():
    doc = load_json(path)
    kind = doc.get("kind", "unknown")
    helm_by_kind.setdefault(kind, []).append((fname, path, doc))

kix_by_kind = {}
for fname, path in kix_files.items():
    doc = load_json(path)
    kind = doc.get("kind", "unknown")
    kix_by_kind.setdefault(kind, []).append((fname, path, doc))

has_diff = False
matched_kix = set()

print("--- Per-resource comparison ---")

for kind, helm_entries in sorted(helm_by_kind.items()):
    kix_entries = kix_by_kind.get(kind, [])
    kix_available = [e for e in kix_entries if e[0] not in matched_kix]

    for helm_fname, helm_path, helm_doc in helm_entries:
        helm_name = helm_doc.get("metadata", {}).get("name", "?")

        if not kix_available:
            print(f"MISSING in kix: {kind}/{helm_name}")
            has_diff = True
            continue

        # Match by name first, then fall back to first available
        kix_match = None
        for entry in kix_available:
            if entry[2].get("metadata", {}).get("name") == helm_name:
                kix_match = entry
                break
        if kix_match is None:
            kix_match = kix_available[0]

        matched_kix.add(kix_match[0])
        kix_available.remove(kix_match)

        kix_fname, kix_path, kix_doc = kix_match
        kix_name = kix_doc.get("metadata", {}).get("name", "?")

        # Compare the normalized JSON
        helm_str = json.dumps(helm_doc, sort_keys=True, indent=2)
        kix_str = json.dumps(kix_doc, sort_keys=True, indent=2)

        if helm_str == kix_str:
            print(f"MATCH: {kind}/{helm_name}")
        else:
            print(f"DIFFERS: {kind}/{helm_name} (kix: {kind}/{kix_name})")
            # Show a simple diff
            helm_lines = helm_str.splitlines()
            kix_lines = kix_str.splitlines()

            # Find differing lines
            max_lines = max(len(helm_lines), len(kix_lines))
            diff_count = 0
            for i in range(max_lines):
                h = helm_lines[i] if i < len(helm_lines) else "<missing>"
                k = kix_lines[i] if i < len(kix_lines) else "<missing>"
                if h != k:
                    if diff_count < 30:  # Cap output
                        print(f"  helm: {h.strip()}")
                        print(f"  kix:  {k.strip()}")
                        print()
                    diff_count += 1
            if diff_count > 30:
                print(f"  ... and {diff_count - 30} more differences")
            has_diff = True

# Check for extra kix resources not matched to any Helm resource
for kind, kix_entries in sorted(kix_by_kind.items()):
    for kix_fname, kix_path, kix_doc in kix_entries:
        if kix_fname not in matched_kix:
            kix_name = kix_doc.get("metadata", {}).get("name", "?")
            print(f"EXTRA in kix: {kind}/{kix_name}")
            has_diff = True

print()
if not has_diff:
    print("RESULT: Parity achieved!")
    sys.exit(0)
else:
    print("RESULT: Differences found (see above)")
    print()
    print("Notes:")
    print("  - Name differences are expected (kix uses deterministic names, Helm uses release-name)")
    print("  - Focus on: same resource kinds, matching selectors, matching container specs")
    print("  - Cosmetic labels (helm.sh/chart, managed-by) are already stripped")
    sys.exit(1)
