"""
Normalization logic for parity comparison between Helm and kix output.

This module strips cosmetic differences that don't affect runtime behavior,
so the comparison focuses on what actually matters to Kubernetes.

As more charts are migrated, chart-specific normalization can be added here
without cluttering the main comparison script.
"""

from __future__ import annotations
from typing import Any

# --- Labels and annotations that differ cosmetically between Helm and kix ---

# Labels that Helm adds but kix doesn't (or uses different values for).
STRIP_LABELS = {
    "helm.sh/chart",
    "app.kubernetes.io/managed-by",
    "app.kubernetes.io/version",
    "app.kubernetes.io/part-of",
}

# Annotations that Helm adds but kix doesn't produce.
STRIP_ANNOTATIONS = {
    "meta.helm.sh/release-name",
    "meta.helm.sh/release-namespace",
}

# Annotation prefixes — any annotation starting with these is stripped.
STRIP_ANNOTATION_PREFIXES = [
    "checksum/",       # Helm uses checksum/config, checksum/health, etc.
    "build.kix.dev/",  # kix build metadata
    "helm.sh/",        # Helm hook annotations (hook, hook-weight, hook-delete-policy)
]

# Helm prefixes resource names with the release name. kix uses plain app names.
HELM_RELEASE_PREFIX = "release-name-"


def normalize_helm(doc: dict) -> dict:
    """Normalize a Helm-rendered resource for behavioral comparison."""
    if not isinstance(doc, dict):
        return doc

    doc = _strip_labels_and_annotations(doc)
    doc = _normalize_names_recursive(doc)
    doc = _strip_empty_fields(doc)
    doc = _normalize_configmap_data(doc)
    doc = _normalize_paths(doc)
    doc = _sort_arrays(doc)
    return doc


def normalize_kix(doc: dict) -> dict:
    """Normalize a kix-built resource for behavioral comparison."""
    if not isinstance(doc, dict):
        return doc

    doc = _strip_labels_and_annotations(doc)
    doc = _strip_empty_fields(doc)
    doc = _normalize_configmap_data(doc)
    doc = _normalize_paths(doc)
    doc = _sort_arrays(doc)
    return doc


# --- Internals ---


def _strip_labels_and_annotations(doc: dict) -> dict:
    """Remove cosmetic labels and annotations from all metadata locations.

    Handles: top-level metadata, pod template metadata, volumeClaimTemplate metadata.
    """
    for metadata in _find_metadata_blocks(doc):
        # Strip labels
        labels = metadata.get("labels", {})
        for key in STRIP_LABELS:
            labels.pop(key, None)

        # Strip annotations by exact key and by prefix
        annotations = metadata.get("annotations", {})
        for key in list(annotations.keys()):
            if key in STRIP_ANNOTATIONS:
                del annotations[key]
                continue
            for prefix in STRIP_ANNOTATION_PREFIXES:
                if key.startswith(prefix):
                    del annotations[key]
                    break

        # Remove empty annotations dict to avoid false diffs
        if not annotations and "annotations" in metadata:
            del metadata["annotations"]

    return doc


def _find_metadata_blocks(doc: dict) -> list[dict]:
    """Find all metadata dicts in a resource that may contain labels/annotations.

    Returns metadata blocks from:
    - Top-level .metadata
    - Pod template .spec.template.metadata
    - VolumeClaimTemplates[*].metadata
    """
    blocks = []

    top = doc.get("metadata")
    if isinstance(top, dict):
        blocks.append(top)

    tmpl = doc.get("spec", {}).get("template", {}).get("metadata")
    if isinstance(tmpl, dict):
        blocks.append(tmpl)

    for vct in doc.get("spec", {}).get("volumeClaimTemplates", []):
        if isinstance(vct, dict):
            vct_meta = vct.get("metadata")
            if isinstance(vct_meta, dict):
                blocks.append(vct_meta)

    return blocks


def _normalize_names_recursive(obj: Any) -> Any:
    """Strip Helm release-name- prefix from all string values.

    Helm names resources 'release-name-valkey' while kix uses 'valkey'.
    This applies to name fields, but also to embedded references in env var
    values like 'valkey-primary-0.release-name-valkey-headless.default...'.
    We strip ALL occurrences of the prefix in every string value.
    """
    if isinstance(obj, dict):
        return {k: _normalize_names_recursive(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [_normalize_names_recursive(item) for item in obj]
    elif isinstance(obj, str) and HELM_RELEASE_PREFIX in obj:
        return obj.replace(HELM_RELEASE_PREFIX, "")
    return obj


def _strip_empty_fields(obj: Any) -> Any:
    """Remove null values, empty dicts, and empty lists recursively.

    Helm templates sometimes emit empty fields like `seLinuxOptions: {}`,
    `supplementalGroups: []`, or `seccompProfile: null` that kix's removeNulls
    already strips. Normalizing both sides prevents false diffs.
    """
    if isinstance(obj, dict):
        result = {}
        for k, v in obj.items():
            v = _strip_empty_fields(v)
            if v is None:
                continue
            if isinstance(v, dict) and not v:
                continue
            if isinstance(v, list) and not v:
                continue
            result[k] = v
        return result
    elif isinstance(obj, list):
        return [_strip_empty_fields(item) for item in obj]
    return obj


def _normalize_configmap_data(doc: dict) -> dict:
    """Normalize whitespace in ConfigMap data values.

    - Strip trailing whitespace (builtins.readFile preserves trailing newlines)
    - Collapse runs of blank lines to a single newline (Nix string interpolation
      of empty values can leave extra blank lines that Helm doesn't produce)
    """
    import re
    if doc.get("kind") != "ConfigMap":
        return doc
    data = doc.get("data")
    if isinstance(data, dict):
        doc = dict(doc)
        def normalize_text(v: str) -> str:
            # Strip trailing whitespace from each line, collapse blank lines, strip ends
            lines = [line.rstrip() for line in v.splitlines()]
            return re.sub(r"\n{2,}", "\n", "\n".join(lines)).strip()
        doc["data"] = {k: normalize_text(v) if isinstance(v, str) else v
                       for k, v in data.items()}
    return doc


def _normalize_paths(obj: Any) -> Any:
    """Strip trailing slashes from mount paths.

    Kubernetes treats '/foo/bar/' and '/foo/bar' identically.
    Helm sometimes includes trailing slashes, kix doesn't.
    """
    if isinstance(obj, dict):
        result = {}
        for k, v in obj.items():
            if k == "mountPath" and isinstance(v, str) and len(v) > 1:
                result[k] = v.rstrip("/")
            else:
                result[k] = _normalize_paths(v)
        return result
    elif isinstance(obj, list):
        return [_normalize_paths(item) for item in obj]
    return obj


def _sort_arrays(obj: Any) -> Any:
    """Sort arrays where ordering is not semantically significant.

    Ports, env vars, and volume mounts may appear in different orders
    between Helm and kix. Kubernetes doesn't care about ordering for these.
    """
    if isinstance(obj, dict):
        result = {}
        for k, v in obj.items():
            if k == "ports" and isinstance(v, list) and v and isinstance(v[0], dict):
                result[k] = sorted(v, key=lambda p: (p.get("name", ""), p.get("protocol", "")))
            elif k == "env" and isinstance(v, list) and v and isinstance(v[0], dict):
                result[k] = sorted(v, key=lambda e: e.get("name", ""))
            elif k == "volumeMounts" and isinstance(v, list) and v and isinstance(v[0], dict):
                result[k] = sorted(v, key=lambda vm: vm.get("mountPath", ""))
            elif k == "volumes" and isinstance(v, list) and v and isinstance(v[0], dict):
                result[k] = sorted(v, key=lambda vol: vol.get("name", ""))
            else:
                result[k] = _sort_arrays(v)
        return result
    elif isinstance(obj, list):
        return [_sort_arrays(item) for item in obj]
    return obj


def resource_key(doc: dict) -> str:
    """Generate a comparison key from kind + name."""
    kind = doc.get("kind", "Unknown")
    name = doc.get("metadata", {}).get("name", "unknown")
    return f"{kind}/{name}"
